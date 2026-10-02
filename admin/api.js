const API_BASE = '/_authz/api'

async function request (path, options = {}) {
  const { csrf, headers = {}, values, ...fetchOptions } = options
  const response = await fetch(`${API_BASE}${path}`, {
    credentials: 'same-origin',
    headers: {
      Accept: 'application/json',
      ...(values ? { 'Content-Type': 'application/json' } : {}),
      ...(csrf ? { 'X-CSRF-Token': csrf } : {}),
      ...headers
    },
    ...(values ? { body: JSON.stringify(values) } : {}),
    ...fetchOptions
  })

  const contentType = response.headers.get('content-type') || ''
  const data = contentType.includes('application/json')
    ? await response.json()
    : null

  if (!response.ok) {
    const error = new Error(data?.error?.message || data?.message || `HTTP ${response.status}`)
    error.status = response.status
    error.code = data?.error?.code || ''
    throw error
  }

  return data?.data
}

function mutation (method, path, values) {
  const { _csrf: csrf, ...payload } = values
  return request(path, { method, csrf, values: payload })
}

async function fetchJson (url) {
  const response = await fetch(url, {
    credentials: 'same-origin',
    headers: { Accept: 'application/json' }
  })
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`)
  }
  return response.json()
}

function saveUser (values) {
  if (values.action === 'create') return mutation('POST', '/users', values)
  if (values.action === 'delete') return mutation('DELETE', `/users/${values.id}`, values)
  if (values.action === 'resetpw') return mutation('PUT', `/users/${values.id}/password`, { ...values, password: values.newpw })
  if (values.action === 'setroles') return mutation('PATCH', `/users/${values.id}`, values)
  if (values.action === 'enable' || values.action === 'disable') {
    return mutation('PATCH', `/users/${values.id}`, { ...values, enabled: values.action === 'enable' })
  }
  throw new Error('Unsupported user action')
}

function saveRemoteUser (values) {
  const provider = encodeURIComponent(values.provider)
  if (values.action === 'delete') return mutation('DELETE', `/remote-users/${provider}`, values)
  if (values.action === 'enable' || values.action === 'disable') {
    return mutation('PATCH', `/remote-users/${provider}`, { ...values, enabled: values.action === 'enable' })
  }
  return mutation('PATCH', `/remote-users/${provider}`, values)
}

function saveApplication (values) {
  if (values.action === 'create') return mutation('POST', '/applications', values)
  if (values.action === 'edit') return mutation('PATCH', `/applications/${values.id}`, values)
  if (values.action === 'toggle') return mutation('PATCH', `/applications/${values.id}`, values)
  if (values.action === 'delete') return mutation('DELETE', `/applications/${values.id}`, values)
  throw new Error('Unsupported application action')
}

function savePolicy (values) {
  if (values.action === 'add') return mutation('POST', '/policies', values)
  if (values.action === 'edit') return mutation('PATCH', `/policies/${values.id}`, values)
  if (values.action === 'del') return mutation('DELETE', `/policies/${values.id}`, values)
  throw new Error('Unsupported policy action')
}

function saveMenuEntry (values) {
  if (values.action === 'create') return mutation('POST', '/menu-entries', values)
  if (values.action === 'edit') return mutation('PATCH', `/menu-entries/${values.id}`, values)
  if (values.action === 'reorder') return mutation('PUT', '/menu-entries/reorder', values)
  if (values.action === 'delete') return mutation('DELETE', `/menu-entries/${values.id}`, values)
  throw new Error('Unsupported menu entry action')
}

// 域名服务/本地服务条目：键为 binding:<id> / port:<port>，无删除语义。
function saveMenuService (values) {
  const { action, id, ...payload } = values
  if (action === 'edit') return mutation('PATCH', `/menu-services/${encodeURIComponent(id)}`, payload)
  // payload 保留 _csrf，由 mutation 提取为请求头并从 body 中剔除。
  if (action === 'reset') return mutation('DELETE', `/menu-services/${encodeURIComponent(id)}`, payload)
  if (action === 'reorder') return mutation('PUT', '/menu-services/reorder', payload)
  throw new Error('Unsupported menu service action')
}

function saveNginxConf (values) {
  if (values.action === 'validate') return mutation('POST', '/nginx-conf/validate', values)
  if (values.action === 'save') return mutation('PUT', '/nginx-conf', values)
  if (values.action === 'reload') return mutation('POST', '/nginx-conf/reload', values)
  throw new Error('Unsupported nginx conf action')
}

// API 管理：创建与轮换都返回一次性明文 token（库里只存摘要，事后不可回看）；
// 角色/启停/删除走标准动作。
// 文件管理：上传走 multipart（不经 JSON mutation），重命名/删除是普通 JSON。
// 上传前先取会话拿 CSRF（浏览器会话才有；API Key 没有会话也就进不去写接口）。
async function uploadFiles (path, files, overwrite) {
  const session = await request('/session')
  const form = new FormData()
  for (const file of files) form.append('file', file, file.name)
  const query = new URLSearchParams({ path: path || '' })
  if (overwrite) query.set('overwrite', '1')
  const response = await fetch(`${API_BASE}/files/upload?${query}`, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'X-CSRF-Token': session.csrf || '' },
    body: form
  })
  const data = await response.json().catch(() => null)
  if (!response.ok) {
    const error = new Error(data?.error?.message || `HTTP ${response.status}`)
    error.status = response.status
    throw error
  }
  return data?.data
}

function saveApiKey (values) {
  const { action, id, ...payload } = values
  if (action === 'create') return mutation('POST', '/api-keys', payload)
  if (action === 'edit') return mutation('PATCH', `/api-keys/${id}`, payload)
  if (action === 'rotate') return mutation('POST', `/api-keys/${id}/rotate`, payload)
  if (action === 'delete') return mutation('DELETE', `/api-keys/${id}`, payload)
  throw new Error('Unsupported api key action')
}

// 对象存储（S3）：列表是 GET 查询参数，mkdir/rename/remove 是普通 JSON mutation，
// 上传与 files 同构（multipart + X-CSRF-Token，全同名冲突 409 触发覆盖确认）。
// 多套 S3 服务配置上线后，这一族方法都接受可选的 cfg（配置 id 或 name）：
// 显式传值时 GET/上传附加 ?cfg=<id>，JSON mutation 在 body 里带 cfg 字段；
// 不传（undefined/null/''）时 URL 与 body 与旧版逐字节一致，向后兼容。
function appendCfg (query, cfg) {
  if (cfg !== undefined && cfg !== null && cfg !== '') query.set('cfg', String(cfg))
  return query
}

function s3Info (bucket, cfg) {
  const query = new URLSearchParams()
  if (bucket) query.set('bucket', bucket)
  appendCfg(query, cfg)
  const suffix = query.toString()
  return request('/s3' + (suffix ? '?' + suffix : ''))
}

function s3List (bucket, path, token, cfg) {
  const query = new URLSearchParams({ bucket: bucket, path: path || '' })
  if (token) query.set('token', token)
  appendCfg(query, cfg)
  return request('/s3?' + query)
}

async function uploadS3 (bucket, path, files, overwrite, opts) {
  const session = await request('/session')
  const form = new FormData()
  for (const file of files) form.append('file', file, file.name)
  const query = new URLSearchParams({ bucket: bucket, path: path || '' })
  if (overwrite) query.set('overwrite', '1')
  if (opts && opts.mkdir) query.set('mkdir', '1')
  if (opts) appendCfg(query, opts.cfg)
  const response = await fetch(`${API_BASE}/s3/upload?${query}`, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'X-CSRF-Token': session.csrf || '' },
    body: form
  })
  const data = await response.json().catch(() => null)
  if (!response.ok) {
    const error = new Error(data?.error?.message || `HTTP ${response.status}`)
    error.status = response.status
    throw error
  }
  return data?.data
}

// S3 服务配置管理（/_authz/api/s3-configs）：cfg 永不回显 secret_access_key，
// 列表只给 has_secret 与 access_key_id_masked，所以编辑表单里 AKID/SECRET
// 留空 = 不修改（与后端 PATCH 语义一致）。id 只出现在路径里，写请求统一
// 提取 _csrf 成 X-CSRF-Token 头（照 saveMenuService 的写法剔除 id）。
function s3Configs () {
  return request('/s3-configs')
}

function createS3Config (values) {
  const { _csrf: csrf, id, ...payload } = values
  return request('/s3-configs', { method: 'POST', csrf, values: payload })
}

function updateS3Config (values) {
  const { _csrf: csrf, id, ...payload } = values
  return request(`/s3-configs/${encodeURIComponent(id)}`, { method: 'PATCH', csrf, values: payload })
}

function deleteS3Config (values) {
  const { _csrf: csrf, id } = values
  // DELETE 无 body：只发方法 + CSRF 头，后端按路径 id 定位。
  return request(`/s3-configs/${encodeURIComponent(id)}`, { method: 'DELETE', csrf })
}

function testS3Config (values) {
  const { _csrf: csrf, id } = values
  // 空对象也要走 JSON 分支：后端读 body 前会先解析 JSON。
  return request(`/s3-configs/${encodeURIComponent(id)}/test`, { method: 'POST', csrf, values: {} })
}

function setDefaultS3Config (values) {
  const { _csrf: csrf, id } = values
  return request(`/s3-configs/${encodeURIComponent(id)}/default`, { method: 'PUT', csrf, values: {} })
}

// 上传记录（过期清理面板）：state 空串 = 不带参数（全部）；limit/offset 服务端分页。
function listUploads (opts = {}) {
  const query = new URLSearchParams()
  if (opts.state) query.set('state', String(opts.state))
  if (opts.limit !== undefined && opts.limit !== null && opts.limit !== '') query.set('limit', String(opts.limit))
  if (opts.offset) query.set('offset', String(opts.offset))
  const suffix = query.toString()
  return request('/uploads' + (suffix ? '?' + suffix : ''))
}

function deleteUpload (values) {
  const { _csrf: csrf, id } = values
  return request(`/uploads/${encodeURIComponent(id)}`, { method: 'DELETE', csrf })
}

function cleanupUploads (values) {
  const { _csrf: csrf, ...payload } = values
  return request('/uploads/cleanup', { method: 'POST', csrf, values: payload })
}

window.adminApi = {
  session: () => request('/session'),
  applications: () => request('/applications'),
  users: () => request('/users'),
  authorization: () => request('/authorization'),
  menuEntries: () => request('/menu-entries'),
  menuTree: () => request('/menu-tree'),
  menuServices: () => request('/menu-services'),
  files: path => request('/files?path=' + encodeURIComponent(path || '')),
  uploadFiles,
  mkdirFile: values => mutation('POST', '/files/mkdir', values),
  renameFile: values => mutation('PUT', '/files/rename', values),
  removeFile: values => mutation('DELETE', '/files/remove', values),
  s3Info,
  s3List,
  uploadS3,
  mkdirS3: values => mutation('POST', '/s3/mkdir', values),
  renameS3: values => mutation('PUT', '/s3/rename', values),
  removeS3: values => mutation('DELETE', '/s3/remove', values),
  s3Configs,
  createS3Config,
  updateS3Config,
  deleteS3Config,
  testS3Config,
  setDefaultS3Config,
  listUploads,
  deleteUpload,
  cleanupUploads,
  nginxConf: () => request('/nginx-conf'),
  apiKeys: () => request('/api-keys'),
  saveUser,
  saveRemoteUser,
  saveBinding: saveApplication,
  savePolicy,
  saveMenuEntry,
  saveMenuService,
  saveNginxConf,
  saveApiKey,
  changePassword: values => mutation('PUT', '/me/password', values),
  logout: values => mutation('DELETE', '/session', values),
  fetchJson
}
