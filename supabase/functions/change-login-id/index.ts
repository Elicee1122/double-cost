// ============================================================
// Edge Function: change-login-id
// 作用：仅修改当前登录账号的虚拟邮箱（email），不改 UID/密码/档案/账单。
// 安全：
//   - 用户身份严格来自请求头 JWT（auth.getUser），不接受任何 uid 字段
//   - 密码校验走 anon 客户端 signInWithPassword，失败即拒绝
//   - service_role key 只在服务端环境变量中读取，绝不下发到浏览器
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const DOMAIN = "dl.example.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  // CORS 预检
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json(405, { error: "仅支持 POST" });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceRoleKey) {
    return json(500, { error: "服务端配置缺失" });
  }

  const anonClient = createClient(url, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const adminClient = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 1) 从 JWT 取当前用户（不接受请求体里的 uid，杜绝改他人账号）
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) {
    return json(401, { error: "未登录" });
  }
  const { data: userData, error: userErr } = await adminClient.auth.getUser(token);
  if (userErr || !userData?.user) {
    return json(401, { error: "登录状态无效，请重新登录" });
  }
  const user = userData.user;
  const currentEmail = user.email || "";

  // 2) 解析并校验入参
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "请求体不是合法 JSON" });
  }
  const newId = String(body?.newId ?? "").trim();
  const confirmId = String(body?.confirmId ?? "").trim();
  const password = String(body?.password ?? "");

  if (!/^\d+$/.test(newId)) {
    return json(400, { error: "账号只能是数字" });
  }
  if (newId.length > 20) {
    return json(400, { error: "账号过长（最多 20 位）" });
  }
  if (newId !== confirmId) {
    return json(400, { error: "两次输入的新账号不一致" });
  }
  if (!password) {
    return json(400, { error: "请输入当前密码" });
  }

  const newEmail = `${newId}@${DOMAIN}`;
  if (newEmail.toLowerCase() === currentEmail.toLowerCase()) {
    return json(200, { ok: true, email: newEmail, unchanged: true });
  }

  // 3) 密码验证（对当前账号做一次真实登录）
  const { error: signInErr } = await anonClient.auth.signInWithPassword({
    email: currentEmail,
    password,
  });
  if (signInErr) {
    return json(403, { error: "密码不对" });
  }

  // 4) 占用检查：扫描是否存在同邮箱的其他账号
  try {
    const { data: listData, error: listErr } =
      await adminClient.auth.admin.listUsers({ page: 1, perPage: 1000 });
    if (!listErr && listData?.users) {
      for (const u of listData.users) {
        if (u.id !== user.id && (u.email || "").toLowerCase() === newEmail.toLowerCase()) {
          return json(409, { error: "该账号已被占用" });
        }
      }
    }
  } catch {
    // 列表失败不阻断，交给下面的 update 兜底
  }

  // 5) 更新邮箱（虚拟邮箱无需确认流程，email_confirm 保证立即可登录）
  const { error: updateErr } = await adminClient.auth.admin.updateUserById(
    user.id,
    { email: newEmail, email_confirm: true },
  );

  if (updateErr) {
    const msg = String(updateErr.message || "");
    if (/already been registered|already registered|already exists/i.test(msg)) {
      return json(409, { error: "该账号已被占用" });
    }
    return json(500, { error: "修改失败：" + msg });
  }

  return json(200, { ok: true, email: newEmail });
});
