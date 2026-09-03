const { createApp, computed, onBeforeUnmount, onMounted, reactive, ref, watch } = Vue

// 内置页面：菜单条目里的 builtin 键映射到这些内嵌应用。
const builtInApps = {
  users: 'users.html?v=7',
  authorization: 'authorization.html?v=15',
  menuEditor: 'menu-editor.html?v=11',
  files: 'files.html?v=4',
  nginxConf: 'nginx_conf.html?v=2'
}

function isNavigable (app) {
  if (!app) return false
  if (Object.values(builtInApps).includes(app)) return true
  return /^(https?:\/\/|\/)/.test(app) && !/^\/\//.test(app)
}

// 把树节点解析成可导航的 URL。
function nodeUrl (node) {
  if (node.builtin && builtInApps[node.builtin]) return builtInApps[node.builtin]
  if (node.url) return node.url
  // 动态发现/绑定的本机服务：优先用绑定域名，否则 <port>-当前主机名
  if (node.port) {
    const hostname = node.domain || (node.port + '-' + window.location.hostname)
    const gatewayPort = window.location.port ? (':' + window.location.port) : ''
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
      unsubscribeLocale = window.adminI18n.subscribe(nextLocale => {
        locale.value = nextLocale
        Quasar.Lang.set(nextLocale === 'zh-CN' ? Quasar.Lang.zhCN : Quasar.Lang.enUS)
      })
      loadSession().then(() => {
        refreshTimer = window.setInterval(loadTree, 30000)
      })
    })

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
