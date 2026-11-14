-- ============================================================
-- 双人记账 · Supabase 数据库结构（阶段 1 审核稿 v3 · 尚未执行）
-- 适用：Supabase PostgreSQL 15+
-- 特性：整份脚本可重复执行；RLS 全程开启；不含任何密钥
--
-- v3 相对 v2 的修改：
--   [1] 新增 bills_guard 触发器：created_by（及 created_at）创建后不可改，
--       其他字段仍由两个账号自由互改
--   [2] profiles_guard 补 created_at，并配合列级授权：
--       authenticated 只被授予 display_name / avatar_url 的 UPDATE
--   [3] 权限段改为「先 revoke 再 grant」，避免 Supabase 默认表权限
--       绕过列级限制
--   [4] 预算约束保持 amount > 0（前端 parseAmt 明确拒绝 0，见下方说明）
--   [5] 自检新增：触发器清单、列级权限核对
--
-- 执行顺序：
--   1) 第 1~7 段：一次执行（建表、索引、函数、触发器、RLS、权限）
--   2) 第 8 段：先在 Dashboard 建两个 Auth 账号，再按注释逐步执行
--   3) 第 9 段：自检
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 1. 表结构
-- ------------------------------------------------------------

-- 共享空间（两个人的账本属于同一个 household）
create table if not exists public.households (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default '我们的账本',
  created_at  timestamptz not null default now()
);
comment on table public.households is '共享空间；两个人同属一条记录';

-- 成员档案：与 auth.users 一一对应，决定"这个账号是 A 还是 B"
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  household_id  uuid not null references public.households(id) on delete cascade,
  slot          text not null check (slot in ('A','B')),
  display_name  text not null default '',
  avatar_url    text,
  created_at    timestamptz not null default now(),
  unique (household_id, slot)
);
comment on table public.profiles is '账号档案；slot=A/B 决定身份，display_name 为页面昵称';
comment on column public.profiles.avatar_url is '预留：当前用昵称首字生成头像，不启用上传';

-- 账单
create table if not exists public.bills (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  ledger_key    text not null check (ledger_key in
                  ('weekly_grocery','monthly_stock','fun','personal_A','personal_B')),
  category      text not null default '',
  note          text not null default '',
  amount        numeric(10,2) not null check (amount > 0 and amount <= 10000000),
  bill_date     date not null,
  payer         text not null check (payer in ('A','B')),
  created_by    uuid not null default auth.uid() references auth.users(id),
  legacy_id     text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.bills is '账单；personal_A/personal_B 仅作分类，不做数据隔离';
comment on column public.bills.ledger_key is '五个账本：共同3个 + 个人2个';
comment on column public.bills.amount is '单位：元，两位小数';
comment on column public.bills.bill_date is '纯日期，避免时区偏移';
comment on column public.bills.legacy_id is '旧 localStorage 账单 id，用于迁移去重';
comment on column public.bills.created_by is '创建人，写入后由触发器锁定不可修改';

-- 默认预算（对应 localStorage 的 dl.v2budgets）
-- 约束说明：前端 parseAmt 拒绝 <=0 与 >99999.99，因此 amount > 0
create table if not exists public.ledger_budgets (
  household_id  uuid not null references public.households(id) on delete cascade,
  ledger_key    text not null check (ledger_key in
                  ('weekly_grocery','monthly_stock','fun','personal_A','personal_B')),
  amount        numeric(10,2) not null check (amount > 0),
  updated_at    timestamptz not null default now(),
  primary key (household_id, ledger_key)
);
comment on table public.ledger_budgets is '各账本的默认预算（设置页可改，0 不允许）';

-- 本期预算覆盖（对应 dl.v2pb，period_key = '2026-11-09' 或 '2026-11'）
-- 约束说明：与默认预算一致，0 不允许（前端保存时会拦下）
create table if not exists public.budget_overrides (
  household_id  uuid not null references public.households(id) on delete cascade,
  ledger_key    text not null check (ledger_key in
                  ('weekly_grocery','monthly_stock','fun','personal_A','personal_B')),
  period_key    text not null check (period_key ~ '^[0-9]{4}-[0-9]{2}(-[0-9]{2})?$'),
  amount        numeric(10,2) not null check (amount > 0),
  updated_at    timestamptz not null default now(),
  primary key (household_id, ledger_key, period_key)
);
comment on table public.budget_overrides is '只影响某一周/某一月的预算，下期自动回默认';

-- ------------------------------------------------------------
-- 2. 索引
-- ------------------------------------------------------------
create index if not exists bills_household_date_idx
  on public.bills (household_id, bill_date desc, created_at desc);

create index if not exists bills_household_ledger_idx
  on public.bills (household_id, ledger_key, bill_date desc);

-- 迁移去重：同一 household 下 legacy_id 唯一
-- （用普通唯一索引而非部分索引，PostgREST/upsert 才能正确推断冲突目标；
--   legacy_id 为 NULL 的新账单彼此不冲突）
create unique index if not exists bills_legacy_uidx
  on public.bills (household_id, legacy_id);

create index if not exists profiles_household_idx
  on public.profiles (household_id);

-- ------------------------------------------------------------
-- 3. 辅助函数与触发器
-- ------------------------------------------------------------

-- 当前登录账号所属的 household
create or replace function public.my_household_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select household_id from public.profiles where id = auth.uid();
$$;

-- 当前登录账号是否属于某个 household
create or replace function public.is_member(hid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.household_id = hid
  );
$$;

-- 自动维护 updated_at
create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- 档案防篡改：普通用户只能改 display_name / avatar_url
-- （column 级授权已限制可写列，这里再做一次触发器兜底）
create or replace function public.profiles_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.id is distinct from old.id then
    raise exception '不允许修改 profiles.id';
  end if;
  if new.household_id is distinct from old.household_id then
    raise exception '不允许修改 household_id';
  end if;
  if new.slot is distinct from old.slot then
    raise exception '不允许修改 slot';
  end if;
  if new.created_at is distinct from old.created_at then
    raise exception '不允许修改 created_at';
  end if;
  return new;
end;
$$;

-- 账单审计字段防篡改：created_by / created_at 写入后不可改
-- 注意：这里不用 RLS 的 with check 实现，因为 with check 无法读取 OLD 值，
--       写成 created_by = auth.uid() 会误伤"B 编辑 A 创建的账单"这一正常场景。
create or replace function public.bills_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.created_by is distinct from old.created_by then
    raise exception '账单创建人不可修改';
  end if;
  if new.created_at is distinct from old.created_at then
    raise exception '账单创建时间不可修改';
  end if;
  return new;
end;
$$;

drop trigger if exists bills_touch on public.bills;
create trigger bills_touch before update on public.bills
  for each row execute function public.touch_updated_at();

drop trigger if exists bills_guard_trg on public.bills;
create trigger bills_guard_trg before update on public.bills
  for each row execute function public.bills_guard();

drop trigger if exists ledger_budgets_touch on public.ledger_budgets;
create trigger ledger_budgets_touch before update on public.ledger_budgets
  for each row execute function public.touch_updated_at();

drop trigger if exists budget_overrides_touch on public.budget_overrides;
create trigger budget_overrides_touch before update on public.budget_overrides
  for each row execute function public.touch_updated_at();

drop trigger if exists profiles_guard_trg on public.profiles;
create trigger profiles_guard_trg before update on public.profiles
  for each row execute function public.profiles_guard();

-- ------------------------------------------------------------
-- 4. 启用 RLS（严禁关闭）
-- ------------------------------------------------------------
alter table public.households       enable row level security;
alter table public.profiles         enable row level security;
alter table public.bills            enable row level security;
alter table public.ledger_budgets   enable row level security;
alter table public.budget_overrides enable row level security;

-- ------------------------------------------------------------
-- 5. 访问策略
--    原则：两人同 household，互相可读可写全部账单（含对方个人账本）
-- ------------------------------------------------------------

-- households：只能看自己所属的空间；前端不能新建/改名/删除
drop policy if exists households_select on public.households;
create policy households_select on public.households
  for select to authenticated
  using (id = public.my_household_id());

-- profiles：能看同空间两人的档案；只能改自己的昵称/头像
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (id = auth.uid() or household_id = public.my_household_id());

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());
-- 注：不设 insert 策略，只有 service_role（后台/SQL 编辑器）能建档案

-- bills：同空间成员全部可读写
drop policy if exists bills_select on public.bills;
create policy bills_select on public.bills
  for select to authenticated
  using (public.is_member(household_id));

drop policy if exists bills_insert on public.bills;
create policy bills_insert on public.bills
  for insert to authenticated
  with check (public.is_member(household_id) and created_by = auth.uid());

drop policy if exists bills_update on public.bills;
create policy bills_update on public.bills
  for update to authenticated
  using (public.is_member(household_id))
  with check (public.is_member(household_id));

drop policy if exists bills_delete on public.bills;
create policy bills_delete on public.bills
  for delete to authenticated
  using (public.is_member(household_id));

-- 默认预算：同空间成员全部可读写
drop policy if exists ledger_budgets_all on public.ledger_budgets;
create policy ledger_budgets_all on public.ledger_budgets
  for all to authenticated
  using (public.is_member(household_id))
  with check (public.is_member(household_id));

-- 本期预算覆盖：同空间成员全部可读写
drop policy if exists budget_overrides_all on public.budget_overrides;
create policy budget_overrides_all on public.budget_overrides
  for all to authenticated
  using (public.is_member(household_id))
  with check (public.is_member(household_id));

-- ------------------------------------------------------------
-- 6. 权限
--    先 revoke（含 authenticated，抵消 Supabase 默认表权限），再精确 grant
-- ------------------------------------------------------------
grant usage on schema public to authenticated;

revoke all on public.households       from public, anon, authenticated;
revoke all on public.profiles         from public, anon, authenticated;
revoke all on public.bills            from public, anon, authenticated;
revoke all on public.ledger_budgets   from public, anon, authenticated;
revoke all on public.budget_overrides from public, anon, authenticated;

-- households：只读
grant select on public.households to authenticated;

-- profiles：可读；只能改两列（配合 profiles_guard 双重保险）
grant select on public.profiles to authenticated;
grant update (display_name, avatar_url) on public.profiles to authenticated;

-- bills：读写删全开（同 household 内两人对等）
grant select, insert, update, delete on public.bills to authenticated;

-- 预算两张表：读写全开
grant select, insert, update, delete on public.ledger_budgets to authenticated;
grant select, insert, update, delete on public.budget_overrides to authenticated;

-- 函数只对登录用户开放
revoke all on function public.my_household_id() from public, anon;
revoke all on function public.is_member(uuid)   from public, anon;
revoke all on function public.touch_updated_at() from public, anon;
revoke all on function public.profiles_guard()   from public, anon;
revoke all on function public.bills_guard()      from public, anon;

grant execute on function public.my_household_id() to authenticated;
grant execute on function public.is_member(uuid)   to authenticated;

-- ------------------------------------------------------------
-- 7. 可选：实时同步（两台设备不刷新也能看到对方新账单）
--    启用需前端配合订阅；不启用也不影响功能
-- ------------------------------------------------------------
-- alter publication supabase_realtime add table public.bills;
-- alter publication supabase_realtime add table public.ledger_budgets;
-- alter publication supabase_realtime add table public.budget_overrides;

-- ============================================================
-- 8. 初始化数据（默认全部注释）
--    前置：已在 Dashboard > Authentication > Users 建好两个邮箱账号
--    步骤：
--      a) 选中下面"8.1"整段执行，复制返回的 household id
--      b) 执行 "select id,email from auth.users order by created_at;" 拿两个 uid
--      c) 把 8.2 里的 <HID> <A_UID> <B_UID> 和昵称替换成实际值后执行
--      d) 执行 8.3 写默认预算
-- ============================================================

-- 8.1 建共享空间
-- insert into public.households (name)
-- values ('我们的账本')
-- returning id;

-- 8.2 绑定两个账号（slot 决定谁是 A 谁是 B；display_name 就是页面昵称）
-- insert into public.profiles (id, household_id, slot, display_name) values
--   ('<A_UID>', '<HID>', 'A', 'A'),
--   ('<B_UID>', '<HID>', 'B', 'B');

-- 8.3 默认预算初值（与当前本地一致）
-- insert into public.ledger_budgets (household_id, ledger_key, amount) values
--   ('<HID>', 'weekly_grocery',  60.00),
--   ('<HID>', 'monthly_stock',  240.00),
--   ('<HID>', 'fun',            160.00),
--   ('<HID>', 'personal_A',     200.00),
--   ('<HID>', 'personal_B',     200.00)
-- on conflict (household_id, ledger_key) do nothing;

-- ============================================================
-- 9. 自检（执行 1~8 段后运行，全部应为期望值）
-- ============================================================

-- 9.1 五张表 RLS 全部为 true
-- select tablename, rowsecurity from pg_tables
--   where schemaname='public'
--     and tablename in ('households','profiles','bills','ledger_budgets','budget_overrides')
--   order by tablename;

-- 9.2 策略清单：应共 9 条
--     households 1（select）
--     profiles 2（select/update）
--     bills 4（select/insert/update/delete）
--     ledger_budgets 1（all）
--     budget_overrides 1（all）
-- select tablename, policyname, cmd, roles
--   from pg_policies where schemaname='public'
--   order by tablename, cmd;

-- 9.3 账号绑定是否正确
-- select p.slot, p.display_name, u.email, p.household_id
--   from public.profiles p join auth.users u on u.id = p.id
--   order by p.slot;

-- 9.4 默认预算是否写入
-- select ledger_key, amount from public.ledger_budgets order by ledger_key;

-- 9.5 触发器清单：应有 5 个
--     bills: bills_touch, bills_guard_trg
--     profiles: profiles_guard_trg
--     ledger_budgets: ledger_budgets_touch
--     budget_overrides: budget_overrides_touch
-- select event_object_table, trigger_name, event_manipulation
--   from information_schema.triggers
--   where trigger_schema='public'
--   order by event_object_table, trigger_name;

-- 9.6 列级权限：authenticated 对 profiles 只应有 display_name / avatar_url 的 UPDATE
-- select grantee, privilege_type, column_name
--   from information_schema.column_privileges
--   where table_schema='public' and table_name='profiles'
--   order by grantee, privilege_type, column_name;

-- 9.7 表级权限：anon 应查不到任何行（空结果）
-- select grantee, privilege_type
--   from information_schema.table_privileges
--   where table_schema='public' and grantee='anon'
--     and table_name in ('households','profiles','bills','ledger_budgets','budget_overrides');
