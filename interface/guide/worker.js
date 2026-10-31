/**
 * guide.1733.dpdns.org — Singbox-Manager 订阅设置教程站点
 *
 * 站点内容全部由 Workers 静态资源提供（见 wrangler.toml 的 [assets]），
 * 静态文件未命中时才会走到这里，统一下发 404，避免暴露目录结构。
 */

const NOT_FOUND = 'Not Found';

export default {
  async fetch(request) {
    return new Response(NOT_FOUND, {
      status: 404,
      headers: {
        'content-type': 'text/plain;charset=UTF-8',
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
      },
    });
  },
};
