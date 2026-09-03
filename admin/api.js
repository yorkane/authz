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

window.adminApi = {
  session: () => request('/session'),
  applications: () => request('/applications'),
  users: () => request('/users'),
  authorization: () => request('/authorization'),
  menuEntries: () => request('/menu-entries'),
  menuTree: () => request('/menu-tree'),
  files: path => request('/files?path=' + encodeURIComponent(path || '')),
  saveUser,
  saveRemoteUser,
  saveBinding: saveApplication,
  savePolicy,
  saveMenuEntry,
  changePassword: values => mutation('PUT', '/me/password', values),
  logout: values => mutation('DELETE', '/session', values),
  fetchJson
}
