const { createApp, computed, onBeforeUnmount, onMounted, reactive, ref, watch } = Vue

// 内置页面：菜单条目里的 builtin 键映射到这些内嵌应用。
const builtInApps = {
  users: 'users.html?v=7',
  authorization: 'authorization.html?v=15',
  menuEditor: 'menu-editor.html?v=11',
  files: 'files.html?v=5',
  nginxConf: 'nginx_conf.html?v=2'
}

function isNavigable (app) {
  if (!app) return false
  if (Object.values(builtInApps).includes(app)) return true
  return /^(https?:\/\/|\/)/.test(app) && !/^\/\//.test(app)
}

// URL 锚点：菜单点击把目标写进 #<encoded url>，刷新或带锚点打开时据此在
// iframe 中恢复当前页面。内置页面允许省略 ?v= 版本位的简写（#users.html
// 命中 users.html?v=N），按「去掉 ? 后的 base」匹配树节点。
function hashTarget () {
  const raw = String(window.location.hash || '').replace(/^#/, '')
  if (!raw) return ''
  try { return decodeURIComponent(raw) } catch (err) { return raw }
}

function urlBase (url) {
  return String(url || '').split('?')[0]
}

// 把树节点解析成可导航的 URL。
function nodeUrl (node) {
  if (node.builtin && builtInApps[node.builtin]) return builtInApps[node.builtin]
  if (node.url) return node.url
  // 动态发现/绑定的本机服务：优先用绑定域名，否则 <port>-当前主机名
  if (node.port) {
    const hostname = node.domain || (node.port + '-' + window.location.hostname)
    // 不同入口 zone 的端口可以不同（如公网 ws:99、内网 ai-t:443），且外层入口
    // 可能把请求 Host 的 zone 改写后菜单才拼出跨 zone 链接。此时照抄浏览器
    // 当前端口会拼出目标 zone 上不存在的监听，只有同 zone 链接才继承端口。
    const here = window.location.hostname
    const zone = (h) => { const i = h.indexOf('.'); return i < 0 ? h : h.slice(i + 1) }
    const sameZone = hostname === here || zone(hostname) === zone(here)
    const gatewayPort = sameZone && window.location.port ? (':' + window.location.port) : ''
    return window.location.protocol + '//' + hostname + gatewayPort + '/'
  }
  return ''
}

const app = createApp({
  setup () {
    const drawerVisible = ref(true)
    const drawerMini = ref(window.innerWidth < 760)
    const activeApp = ref(builtInApps.users)
    const activeTitle = ref('')
    const authenticated = ref(false)
    const isAdmin = ref(false)
    const username = ref('正在验证')
    const source = ref('')
    const csrf = ref('')
    const groups = ref([])
    const groupOpen = reactive({})
    const locale = ref(window.adminI18n.getLocale())
    const i18n = computed(() => window.adminI18n.messages[locale.value].menu)
    const displayName = computed(() => source.value && source.value !== 'local'
      ? username.value + ' · ' + source.value
      : username.value)
    const toggleIcon = computed(() => drawerMini.value ? 'mdi-chevron-right' : 'mdi-chevron-left')
    const toggleLabel = computed(() => drawerMini.value ? i18n.value.expand : i18n.value.collapse)
    let unsubscribeLocale
    let refreshTimer

    // 当前激活节点所属的分组（用于窄栏展开）。
    const activeGroupId = computed(() => {
      for (const group of groups.value) {
        for (const child of (group.children || [])) {
          if (nodeUrl(child) === activeApp.value) return group.id
        }
      }
      return null
    })

    function navigate (node, event) {
      const url = nodeUrl(node)
      if (!isNavigable(url)) return
      if (event?.ctrlKey || event?.metaKey) {
        window.open(url, '_blank', 'noopener,noreferrer')
        return
      }
      activeApp.value = url
      activeTitle.value = node.label || ''
      syncHash(url)
    }

    // 锚点写入：内置页只存去版本位的简写（users.html），外链存完整 URL。
    // 用 pushState 而非给 location.hash 赋值：不触发 hashchange，避免
    // 与下方监听器互相回环；浏览器前进/后退仍经 hashchange 恢复。
    function hashFor (url) {
      return Object.values(builtInApps).includes(url) ? urlBase(url) : url
    }

    function syncHash (url, replace) {
      const next = '#' + encodeURIComponent(hashFor(url))
      if (window.location.hash === next) return
      const state = { url }
      if (replace) window.history.replaceState(state, '', next)
      else window.history.pushState(state, '', next)
    }

    // 把任意锚点/简写解析成树节点使用的完整 URL（含 ?v= 版本位）。
    function resolveTarget (target) {
      if (!target) return ''
      for (const group of groups.value) {
        for (const child of (group.children || [])) {
          const url = nodeUrl(child)
          if (!url) continue
          if (url === target || urlBase(url) === urlBase(target)) return url
        }
      }
      return target
    }

    function applyHashTarget (replace) {
      const target = resolveTarget(hashTarget())
      if (target && isNavigable(target)) {
        activeApp.value = target
        syncHash(target, replace)
      }
    }

    function toggleGroup (groupId) {
      groupOpen[groupId] = !groupOpen[groupId]
    }

    function toggleDrawer () {
      drawerMini.value = !drawerMini.value
    }

    function syncDrawerState () {
      drawerMini.value = window.innerWidth < 760
    }

    function toggleLocale () {
      window.adminI18n.setLocale(locale.value === 'zh-CN' ? 'en-US' : 'zh-CN')
    }

    async function loadTree () {
      try {
        const tree = await window.adminApi.menuTree()
        groups.value = tree.groups || []
        for (const group of groups.value) {
          if (!(group.id in groupOpen)) {
            // 默认：系统应用与域名服务展开，本地服务（条目多、噪音大）收起；
            // 当前页面所在分组始终展开。
            groupOpen[group.id] = group.builtin !== 'local' || group.id === activeGroupId.value
          }
        }
      } catch (error) {
        if (error?.status === 401) return window.location.replace('/_authz/login?next=%2F_authz%2Fapps%2F')
        groups.value = []
        console.error('Unable to load menu tree:', error)
      }
    }

    async function loadSession () {
      try {
        const session = await window.adminApi.session()
        authenticated.value = true
        isAdmin.value = Boolean(session.admin)
        username.value = session.username || 'Signed in'
        source.value = session.source || 'local'
        csrf.value = session.csrf || ''
        await loadTree()
      } catch (error) {
        if (error?.status === 401) {
          window.location.replace('/_authz/login?next=%2F_authz%2Fapps%2F')
          return
        }
        username.value = '服务不可用'
        console.error('Unable to load admin session:', error)
      }
    }

    async function logout () {
      try {
        await window.adminApi.logout({ _csrf: csrf.value })
      } finally {
        window.location.href = '/_authz/login'
      }
    }

    onMounted(() => {
      window.addEventListener('resize', syncDrawerState)
      // 前进/后退或直接带 #锚点 打开：按锚点恢复 iframe 页面。
      window.addEventListener('popstate', restoreFromHistory)
      window.addEventListener('hashchange', restoreFromHistory)
      unsubscribeLocale = window.adminI18n.subscribe(nextLocale => {
        locale.value = nextLocale
        Quasar.Lang.set(nextLocale === 'zh-CN' ? Quasar.Lang.zhCN : Quasar.Lang.enUS)
      })
      loadSession().then(() => {
        // 树就绪后再解析锚点（内置页简写需要对照树节点补齐 ?v= 版本位）。
        applyHashTarget(true)
        refreshTimer = window.setInterval(loadTree, 30000)
      })
    })

    function restoreFromHistory (event) {
      const url = event?.state?.url
      if (url && isNavigable(url)) {
        activeApp.value = url
        return
      }
      applyHashTarget(true)
    }

    watch(drawerMini, mini => {
      const current = activeGroupId.value
      if (mini) {
        // 收起为窄栏：系统应用与域名服务默认展开（图标直接可见），
        // 本地服务收起（条目多、噪音大）；当前页面所在分组始终展开。
        for (const group of groups.value) {
          groupOpen[group.id] = group.builtin !== 'local' || group.id === current
        }
      } else {
        // 展开为完整侧栏：恢复分组，当前所在分组保持展开。
        for (const group of groups.value) {
          groupOpen[group.id] = group.id === current ? true : (groupOpen[group.id] !== false)
        }
      }
    })

    onBeforeUnmount(() => {
      window.removeEventListener('resize', syncDrawerState)
      window.clearInterval(refreshTimer)
      unsubscribeLocale?.()
    })

    return {
      activeApp,
      activeTitle,
      authenticated,
      displayName,
      drawerMini,
      drawerVisible,
      groupOpen,
      groups,
      i18n,
      isAdmin,
      locale,
      logout,
      navigate,
      nodeUrl,
      toggleDrawer,
      toggleGroup,
      toggleIcon,
      toggleLabel,
      toggleLocale
    }
  }
})

app.use(Quasar)
Quasar.Lang.set(window.adminI18n.getLocale() === 'en-US' ? Quasar.Lang.enUS : Quasar.Lang.zhCN)
Quasar.IconSet.set(Quasar.IconSet.mdiV7)
app.mount('#q-app')
