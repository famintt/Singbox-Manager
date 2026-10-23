#!/usr/bin/env python3
"""把 index.html 内嵌进 worker.js。修改界面后运行：python build.py"""
import json
import io
import os

HEADER = '''/**
 * singbox-manager interface
 * Singbox-Manager 一键SSH命令生成器 - Cloudflare Workers 单文件版
 * 项目地址: https://github.com/famintt/Singbox-Manager
 *
 * 部署方式一(控制台): CF Dashboard -> Workers & Pages -> Create Worker -> 粘贴本文件全部内容 -> Deploy
 * 部署方式二(Wrangler): 本目录下执行 `wrangler deploy` (配置见 wrangler.toml)
 * 部署方式三(GitHub): 推送到 GitHub 后手动运行 "Deploy to Cloudflare Workers" 工作流
 *                     （需配置 CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID 两个 Secrets）
 *
 * 本文件由 build.py 从 index.html 自动生成，请勿直接修改；改界面请编辑 index.html 后重新运行 build.py。
 */

const HTML = %s;

const SECURITY_HEADERS = {
  'content-type': 'text/html;charset=UTF-8',
  'cache-control': 'no-store',
  // 页面仅使用内联 script/style，无外部资源；收紧其余加载与嵌入行为
  'content-security-policy':
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; " +
    "img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
};

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== '/') {
      return new Response('Not Found', { status: 404, headers: SECURITY_HEADERS });
    }
    return new Response(HTML, { headers: SECURITY_HEADERS });
  },
};
'''


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    with io.open(os.path.join(here, 'index.html'), encoding='utf-8') as f:
        html = f.read()
    # VERSION 优先取脚本同目录（check-version 临时重建会复制到同目录），
    # 仓库场景下位于 interface/../VERSION
    version_path = os.path.join(here, 'VERSION')
    if not os.path.isfile(version_path):
        version_path = os.path.join(here, '..', 'VERSION')
    with io.open(version_path, encoding='utf-8') as f:
        version = f.read().strip()
    html = html.replace('__VERSION__', version)

    out = HEADER % json.dumps(html, ensure_ascii=False)
    with io.open(os.path.join(here, 'worker.js'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(out)

    print('worker.js generated:', len(out), 'chars')


if __name__ == '__main__':
    main()
