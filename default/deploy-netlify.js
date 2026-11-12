/*
 * Netlify Drop 部署 —— 纯原生 tar + Node https
 * 零依赖，零注册，一条命令
 */
const fs = require('fs');
const path = require('path');
const https = require('https');
const { execSync } = require('child_process');

const ROOT = __dirname;
const TGZ = path.join(ROOT, 'deploy.tar.gz');

// 1. 打包（用系统 tar，Windows 10+ 自带）
console.log('📦 打包中...');
const exclude = ['node_modules', '.git', 'deploy-netlify.js', 'server.js', 'deploy.tar.gz'];
const exclArgs = exclude.map((e) => `--exclude=${e}`).join(' ');
execSync(`tar -czf "${TGZ}" ${exclArgs} -C "${ROOT}" .`, { stdio: 'inherit' });

const size = (fs.statSync(TGZ).size / 1024).toFixed(1);
console.log(`✅ 打包完成：${size} KB`);

// 2. 上传
const buf = fs.readFileSync(TGZ);
console.log('🚀 上传到 Netlify...');

const boundary = '----NLDROP' + Date.now();
const parts = [];
parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="files"; filename="archive.tar.gz"\r\nContent-Type: application/gzip\r\n\r\n`));
parts.push(buf);
parts.push(Buffer.from(`\r\n--${boundary}\r\nContent-Disposition: form-data; name="type"\r\n\r\ntar\r\n--${boundary}--\r\n`));
const body = Buffer.concat(parts);

const opts = {
  hostname: 'api.netlify.com',
  path: '/api/v1/drops',
  method: 'POST',
  headers: {
    'Content-Type': `multipart/form-data; boundary=${boundary}`,
    'Content-Length': body.length,
    'User-Agent': 'shuangren-zhangji-deploy',
  },
};

const req = https.request(opts, (res) => {
  let data = '';
  res.on('data', (c) => (data += c));
  res.on('end', () => {
    fs.unlinkSync(TGZ);
    console.log('\n📨 原始响应（前600字）：\n', data.slice(0, 600));
    try {
      const j = JSON.parse(data);
      if (j.error) {
        console.error('❌', j.error);
        giveManualHint();
        return;
      }
      console.log('\n🎉 部署成功！\n');
      console.log('═══════════════════════════════════════');
      console.log('  🌐 公网地址：' + (j.url || j.serve_url || j.admin_url || JSON.stringify(j).match(/https[^"]+/g)?.[0] || '（没解析到）'));
      console.log('═══════════════════════════════════════\n');
      console.log('完整 JSON keys:', Object.keys(j).join(', '));
      console.log('📱 iPhone 使用步骤：');
      console.log('  1) iPhone Safari 打开上面这个地址');
      console.log('  2) 底部点分享按钮（方框+箭头）');
      console.log('  3) 下滑找到"添加到主屏幕"，点一下');
      console.log('  4) 桌面上出现图标，点开就是 App\n');
      console.log('⚠️ 注意：Netlify Drop 免费但地址随机，');
      console.log('   这个地址以后可能会过期。');
      console.log('   要永久稳定的话，注册一个免费 Vercel 账号部署。\n');
    } catch {
      console.error('❌ 响应解析失败', data.slice(0, 300));
      giveManualHint();
    }
  });
});
req.on('error', (e) => {
  try { fs.unlinkSync(TGZ); } catch {}
  console.error('❌ 网络错误:', e.message);
  giveManualHint();
});
req.write(body);
req.end();

function giveManualHint(){
  console.log('\n💡 手动方案（2 分钟搞定）：');
  console.log('  1) 浏览器打开 https://app.netlify.com/drop');
  console.log('  2) 把项目文件夹里的 index.html 拖进去');
  console.log('  3) 几秒钟后拿到公网地址，手机打开即可\n');
}
