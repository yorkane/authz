// S3 服务配置组件：s3-configs.html 薄壳页与 s3.html 的「配置」视图共用。
// 运行时编译（quasar-umd 的 Vue 带 compiler），与 browser.js 同一做法；
// 页面只留 <az-s3-configs> 外壳，CRUD/上传记录逻辑全部在本文件。
(function () {
  'use strict'

  const { computed, onBeforeUnmount, onMounted, reactive, ref, watch } = Vue

  // 上传记录分页大小：一次 50 条，「加载更多」按 offset 累加。
  const UPLOAD_PAGE = 50
  // 自动刷新周期（需求固定 5 分钟）。
  const AUTO_REFRESH_MS = 300000

  const s3ConfigsTemplate = `
<main class="workspace-page s3cfg-page" :class="{ 's3cfg-embedded': showBack }">
      <header class="page-heading">
        <div>
          <h1>{{ t.title }}</h1>
          <p>{{ t.description }}</p>
        </div>
        <div class="heading-actions">
          <q-btn v-if="showBack" dense flat no-caps icon="mdi-arrow-left" :label="t.back" @click="$emit('back')"></q-btn>
          <q-btn dense outline no-caps icon="mdi-refresh" :label="t.refresh" :loading="loading" @click="load"></q-btn>
          <q-btn dense unelevated no-caps icon="mdi-plus" :label="t.newCfg" class="primary-button" @click="openCreate"></q-btn>
        </div>
      </header>

      <q-banner v-if="error" rounded class="error-banner q-mb-md">
        <template v-slot:avatar><q-icon name="mdi-alert-circle-outline"></q-icon></template>
        {{ error }}
        <template v-slot:action><q-btn flat dense no-caps :label="t.retry" @click="load"></q-btn></template>
      </q-banner>

      <!-- ── 上半区：存储服务配置列表 ── -->
      <q-card flat class="surface-card">
        <q-card-section class="surface-heading">
          <div><div class="surface-title">{{ t.listTitle }}</div><div class="surface-subtitle">{{ t.listNote }}</div></div>
          <q-input v-model="filter" dense outlined dark debounce="250" :placeholder="t.search" class="search-input">
            <template v-slot:prepend><q-icon name="mdi-magnify"></q-icon></template>
          </q-input>
        </q-card-section>
        <q-separator dark></q-separator>
        <q-table flat dark :rows="configs" :columns="columns" row-key="id" :filter="filter"
                 :loading="loading" :rows-per-page-options="[10, 20, 0]" class="linear-table">
          <template v-slot:body-cell-name="props">
            <q-td :props="props">
              <div class="sc-name-cell">
                <strong>{{ props.row.name }}</strong>
                <q-badge v-if="props.row.virtual" outline color="orange-8">{{ t.envBadge }}</q-badge>
              </div>
              <span class="sc-caption" :class="{ 'sc-caption-warn': props.row.virtual }">
                {{ props.row.virtual ? t.envHint : (props.row.note || '') }}
              </span>
            </q-td>
          </template>
          <template v-slot:body-cell-endpoint="props">
            <q-td :props="props">
              <code class="sc-mono">{{ props.row.endpoint || t.noValue }}</code>
              <q-tooltip>{{ props.row.endpoint }}</q-tooltip>
            </q-td>
          </template>
          <template v-slot:body-cell-region="props"><q-td :props="props">{{ props.row.region || t.noValue }}</q-td></template>
          <template v-slot:body-cell-akid="props">
            <q-td :props="props"><code class="sc-mono">{{ props.row.access_key_id_masked || t.noValue }}</code></q-td>
          </template>
          <template v-slot:body-cell-secret="props">
            <q-td :props="props">
              <q-badge outline :color="isOn(props.row.has_secret) ? 'teal-4' : 'grey-6'"
                       :label="isOn(props.row.has_secret) ? t.secretSet : t.secretUnset"></q-badge>
            </q-td>
          </template>
          <template v-slot:body-cell-writable="props">
            <q-td :props="props">
              <span class="sc-mono">{{ scopeText(props.row) }}</span>
              <span v-if="props.row.share_prefix" class="sc-caption">{{ props.row.share_prefix }}</span>
            </q-td>
          </template>
          <template v-slot:body-cell-expires="props">
            <q-td :props="props">
              <span>{{ expiresText(props.row.expires_hours) }}</span>
            </q-td>
          </template>
          <template v-slot:body-cell-lifecycle="props">
            <q-td :props="props">
              <q-badge outline :color="isOn(props.row.use_bucket_lifecycle) ? 'blue-4' : 'grey-6'"
                       :label="isOn(props.row.use_bucket_lifecycle) ? t.lifecycleOn : t.lifecycleOff"></q-badge>
            </q-td>
          </template>
          <template v-slot:body-cell-default="props">
            <q-td :props="props">
              <q-badge v-if="isOn(props.row.is_default)" color="purple-8" text-color="white" :label="t.isDefault"></q-badge>
              <q-btn v-else flat dense no-caps icon="mdi-check-decagram-outline" :label="t.setDefault"
                     :loading="busy.default === props.row.id" @click="setDefault(props.row)"></q-btn>
            </q-td>
          </template>
          <template v-slot:body-cell-enabled="props">
            <q-td :props="props">
              <!-- env 回落项由环境变量决定，不在此处改写启用状态。 -->
              <q-toggle v-if="!props.row.virtual" :model-value="isOn(props.row.enabled)" color="teal-4"
                        :disable="busy.enabled === props.row.id"
                        @update:model-value="toggleEnabled(props.row, $event)"></q-toggle>
              <q-badge v-else outline :color="isOn(props.row.enabled) ? 'teal-4' : 'grey-6'"
                       :label="isOn(props.row.enabled) ? t.enabled : t.disabled"></q-badge>
            </q-td>
          </template>
          <template v-slot:body-cell-actions="props">
            <q-td :props="props">
              <div class="row-actions">
                <q-btn flat round dense icon="mdi-lan-connect" :loading="busy.test === props.row.id"
                       :disable="busy.test === props.row.id" @click="testCfg(props.row)">
                  <q-tooltip>{{ t.test }}</q-tooltip>
                </q-btn>
                <q-btn flat round dense icon="mdi-pencil-outline" :disable="props.row.virtual" @click="openEdit(props.row)">
                  <q-tooltip>{{ props.row.virtual ? t.envHint : t.edit }}</q-tooltip>
                </q-btn>
                <q-btn flat round dense icon="mdi-trash-can-outline" color="red-4"
                       :disable="props.row.virtual" @click="removeCfg(props.row)">
                  <q-tooltip>{{ props.row.virtual ? t.envHint : t.deleteAction }}</q-tooltip>
                </q-btn>
              </div>
            </q-td>
          </template>
          <template v-slot:no-data>
            <div class="full-width row flex-center q-pa-xl empty-state">
              <q-icon name="mdi-bucket-outline" size="28px"></q-icon><span>{{ t.noData }}</span>
            </div>
          </template>
        </q-table>
      </q-card>

      <!-- ── 下半区：上传记录（过期清理） ── -->
      <q-card flat class="surface-card q-mt-lg">
        <q-card-section class="surface-heading">
          <div><div class="surface-title">{{ t.uploadsTitle }}</div><div class="surface-subtitle">{{ t.uploadsNote }}</div></div>
          <q-btn outline dense no-caps icon="mdi-broom" :label="busy.cleanup ? t.cleanupRunning : t.cleanup"
                 class="secondary-button" :loading="busy.cleanup" :disable="busy.cleanup" @click="runCleanup"></q-btn>
        </q-card-section>
        <q-separator dark></q-separator>
        <div class="sc-toolbar">
          <q-select v-model="uploadState" dense outlined dark :options="stateOptions" emit-value map-options
                    :label="t.colState" class="sc-filter" @update:model-value="reloadUploads"></q-select>
          <span class="sc-toolbar-info">{{ loadedText }}</span>
          <div class="sc-toolbar-actions">
            <q-toggle v-model="autoRefresh" color="teal-4" :label="t.autoRefresh"></q-toggle>
            <q-btn flat dense no-caps icon="mdi-refresh" :label="t.refresh" :loading="uploadsLoading" @click="reloadUploads"></q-btn>
          </div>
        </div>
        <q-separator dark></q-separator>
        <q-table flat dark :rows="uploads" :columns="uploadColumns" row-key="id"
                 :loading="uploadsLoading" :rows-per-page-options="[0]" class="linear-table">
          <template v-slot:body-cell-created_at="props"><q-td :props="props">{{ formatDate(props.row.created_at) }}</q-td></template>
          <template v-slot:body-cell-cfg="props"><q-td :props="props">{{ cfgName(props.row.cfg_id) }}</q-td></template>
          <template v-slot:body-cell-bucket="props"><q-td :props="props">{{ props.row.bucket || t.noValue }}</q-td></template>
          <template v-slot:body-cell-key="props">
            <q-td :props="props"><code class="sc-mono">{{ props.row.key }}</code><q-tooltip>{{ props.row.key }}</q-tooltip></q-td>
          </template>
          <template v-slot:body-cell-size="props"><q-td :props="props">{{ sizeText(props.row.size) }}</q-td></template>
          <template v-slot:body-cell-source="props"><q-td :props="props">{{ props.row.created_by || t.noValue }}</q-td></template>
          <template v-slot:body-cell-expiry="props"><q-td :props="props">{{ expiryText(props.row) }}</q-td></template>
          <template v-slot:body-cell-state="props">
            <q-td :props="props"><q-badge outline :color="stateColor(props.row.state)" :label="props.row.state || t.noValue"></q-badge></q-td>
          </template>
          <template v-slot:body-cell-last_error="props">
            <q-td :props="props">
              <span class="sc-mono" :class="{ 'sc-caption-warn': props.row.last_error }">{{ props.row.last_error || t.noValue }}</span>
              <q-tooltip v-if="props.row.last_error">{{ props.row.last_error }}</q-tooltip>
            </q-td>
          </template>
          <template v-slot:body-cell-actions="props">
            <q-td :props="props">
              <div class="row-actions">
                <q-btn flat round dense icon="mdi-delete-outline" color="red-4"
                       :loading="busy.upload === props.row.id" :disable="busy.upload === props.row.id"
                       @click="removeUpload(props.row)">
                  <q-tooltip>{{ t.deleteUpload }}</q-tooltip>
                </q-btn>
              </div>
            </q-td>
          </template>
          <template v-slot:no-data>
            <div class="full-width row flex-center q-pa-xl empty-state">
              <q-icon name="mdi-upload-outline" size="28px"></q-icon><span>{{ t.noData }}</span>
            </div>
          </template>
        </q-table>
        <q-separator dark></q-separator>
        <div class="sc-toolbar">
          <q-btn flat dense no-caps icon="mdi-chevron-down" :label="t.loadMore"
                 :disable="!canLoadMore" :loading="uploadsLoading" @click="loadMoreUploads"></q-btn>
        </div>
      </q-card>

      <!-- ── 新建 / 编辑对话框 ── -->
      <q-dialog v-model="formOpen">
        <q-card class="dialog-card s3cfg-dialog-card">
          <q-form @submit="saveForm">
            <q-card-section>
              <div class="dialog-title">{{ editingId ? t.editTitle : t.createTitle }}</div>
              <div class="dialog-copy">{{ editingId ? t.editCopy : t.createCopy }}</div>
              <div v-if="editingId && formDraft.virtual" class="dialog-copy">{{ t.envHint }}</div>
              <div v-if="editingId && formDraft.share_prefix" class="dialog-copy">
                {{ t.shareRoot }}: <code class="sc-mono">{{ formDraft.share_prefix }}</code>
              </div>
            </q-card-section>
            <q-banner v-if="isPlainHttp" dense rounded class="s3cfg-warn-banner q-mx-md">
              <template v-slot:avatar><q-icon name="mdi-alert-octagon-outline"></q-icon></template>
              {{ t.allowHttpWarn }}
            </q-banner>
            <q-separator dark></q-separator>
            <q-card-section class="s3cfg-dialog-fields">
              <q-input v-model.trim="form.name" dark outlined :label="t.cfgName" :hint="t.cfgNameHint"
                       :readonly="Boolean(editingId)" :rules="[required, validName]"></q-input>
              <q-input v-model.trim="form.endpoint" dark outlined :label="t.endpoint" :hint="t.endpointHint"
                       :rules="[required, validEndpoint]"></q-input>
              <div class="s3cfg-grid">
                <q-input v-model.trim="form.region" dark outlined :label="t.region" :hint="t.regionHint"></q-input>
                <q-input v-model.trim="form.default_bucket" dark outlined :label="t.defaultBucket" :hint="t.defaultBucketHint"></q-input>
                <q-input v-model.trim="form.access_key_id" dark outlined :label="t.akid"
                         :hint="editingId ? undefined : t.akidRule" :type="revealSecret ? 'text' : 'password'"
                         autocomplete="new-password" :rules="[requiredAkid]">
                  <template v-slot:append>
                    <q-btn flat round dense :icon="revealSecret ? 'mdi-eye-off-outline' : 'mdi-eye-outline'"
                           @click="revealSecret = !revealSecret"></q-btn>
                  </template>
                </q-input>
                <q-input v-model="form.secret_access_key" dark outlined :label="t.secret"
                         :placeholder="secretPlaceholder" :hint="secretHint" type="password" autocomplete="new-password"
                         :rules="[requiredSecret]">
                  <template v-slot:append>
                    <q-btn flat round dense :icon="revealSecret ? 'mdi-eye-off-outline' : 'mdi-eye-outline'"
                           @click="revealSecret = !revealSecret"></q-btn>
                  </template>
                </q-input>
                <q-input v-model.number="form.expires_hours" dark outlined type="number" :label="t.expiresHours"
                         :hint="t.expiresHoursHint" min="0" max="720" step="1" :rules="[validExpiresHours]"></q-input>
                <q-input v-model.trim="form.share_bucket" dark outlined :label="t.shareBucket" :hint="t.shareBucketHint"></q-input>
                <q-input v-model.trim="form.share_root" dark outlined :label="t.shareRoot" :hint="t.shareRootHint"></q-input>
              </div>
              <q-input v-model="form.writable_paths" dark outlined type="textarea" autogrow class="s3cfg-paths"
                       :label="t.writablePaths" :hint="t.writablePathsHint"></q-input>
              <q-input v-model="form.note" dark outlined type="textarea" autogrow class="s3cfg-note-field"
                       :label="t.note"></q-input>
              <div class="s3cfg-grid">
                <q-toggle v-model="form.allow_http" color="orange-7" :label="t.allowHttp" :disable="!isPlainHttp"></q-toggle>
                <q-toggle v-model="form.use_bucket_lifecycle" color="teal-4" :label="t.useLifecycle"></q-toggle>
              </div>
              <div class="dialog-copy">{{ t.allowHttpHint }}</div>
              <div class="dialog-copy">{{ t.useLifecycleHint }}</div>
              <q-toggle v-model="form.enabled" color="teal-4" :label="t.cfgEnabled"></q-toggle>
            </q-card-section>
            <q-card-actions align="right">
              <q-btn flat no-caps :label="t.cancel" :disable="saving" v-close-popup></q-btn>
              <q-btn unelevated no-caps type="submit" :label="t.save" class="primary-button" :loading="saving"></q-btn>
            </q-card-actions>
          </q-form>
        </q-card>
      </q-dialog>
    </main>`

  const component = {
    name: 'AzS3Configs',
    // showBack=true（s3.html 内嵌的配置视图）：头部出现返回按钮并回调宿主；
    // 薄壳独立页保持原行为。
    props: { showBack: { type: Boolean, default: false } },
    emits: ['back'],
    template: s3ConfigsTemplate,
    setup (props) {
        const locale = ref(window.adminI18n.getLocale())
        const t = computed(() => window.adminI18n.messages[locale.value].s3Configs)
        const csrf = ref('')
        const loading = ref(false)
        const error = ref('')
        const filter = ref('')
        const configs = ref([])
        const busy = reactive({ test: 0, enabled: 0, default: 0, upload: 0, cleanup: 0 })
        // 对话框状态：editingId = 0 表示新建；formDraft 保存打开时的后端原行，
        // 用于判断 virtual / share_prefix（不可编辑的信息位）。
        const formOpen = ref(false)
        const saving = ref(false)
        const editingId = ref(0)
        const revealSecret = ref(false)
        const form = reactive(emptyForm())
        const formDraft = reactive({ virtual: false, has_secret: false, share_prefix: '' })
        // 上传记录：state 过滤 + offset 分页 + 5 分钟自动刷新开关。
        const uploads = ref([])
        const uploadTotal = ref(0)
        const uploadState = ref('')
        const uploadsLoading = ref(false)
        const autoRefresh = ref(true)
        // 每分钟推进一次的“当前时间”：剩余有效期文案要随时间自己走动。
        const now = ref(Date.now())
        let unsubscribeLocale
        let refreshTimer
        let tickTimer

        function emptyForm () {
          return {
            name: '', endpoint: '', region: '', access_key_id: '', secret_access_key: '',
            writable_paths: '', share_root: '', share_bucket: '',
            expires_hours: 0, use_bucket_lifecycle: false, default_bucket: '',
            allow_http: false, enabled: true, note: ''
          }
        }

        const columns = computed(() => [
          { name: 'name', label: t.value.colName, field: 'name', align: 'left', sortable: true, style: 'min-width:200px' },
          { name: 'endpoint', label: t.value.colEndpoint, field: 'endpoint', align: 'left', sortable: true },
          { name: 'region', label: t.value.colRegion, field: 'region', align: 'left', classes: 'sc-opt', headerClasses: 'sc-opt' },
          { name: 'akid', label: t.value.colAkid, field: 'access_key_id_masked', align: 'left', classes: 'sc-opt', headerClasses: 'sc-opt' },
          { name: 'secret', label: t.value.colSecret, field: 'has_secret', align: 'left', classes: 'sc-opt', headerClasses: 'sc-opt' },
          { name: 'writable', label: t.value.colWritable, field: 'writable_paths', align: 'left', style: 'min-width:180px' },
          { name: 'expires', label: t.value.colExpires, field: 'expires_hours', align: 'left' },
          { name: 'lifecycle', label: t.value.colLifecycle, field: 'use_bucket_lifecycle', align: 'left', classes: 'sc-opt', headerClasses: 'sc-opt' },
          { name: 'default', label: t.value.colDefault, field: 'is_default', align: 'left' },
          { name: 'enabled', label: t.value.colStatus, field: 'enabled', align: 'left' },
          { name: 'actions', label: '', field: 'actions', align: 'right' }
        ])

        const uploadColumns = computed(() => [
          { name: 'created_at', label: t.value.colCreated, field: 'created_at', align: 'left', sortable: true, style: 'min-width:170px;white-space:nowrap' },
          { name: 'kind', label: t.value.colKind, field: 'kind', align: 'left', classes: 'sc-opt', headerClasses: 'sc-opt' },
          { name: 'cfg', label: t.value.colCfg, field: 'cfg_id', align: 'left', classes: 'sc-opt', headerClasses: 'sc-opt' },
          { name: 'bucket', label: t.value.colBucket, field: 'bucket', align: 'left' },
          { name: 'key', label: t.value.colKey, field: 'key', align: 'left', style: 'min-width:220px' },
          { name: 'size', label: t.value.colSize, field: 'size', align: 'left', sortable: true },
          { name: 'source', label: t.value.colOwner, field: 'created_by', align: 'left', classes: 'sc-opt', headerClasses: 'sc-opt' },
          { name: 'expiry', label: t.value.colExpiry, field: 'expires_at', align: 'left', style: 'min-width:150px' },
          { name: 'state', label: t.value.colState, field: 'state', align: 'left' },
          { name: 'last_error', label: t.value.colError, field: 'last_error', align: 'left', classes: 'sc-opt', headerClasses: 'sc-opt' },
          { name: 'actions', label: '', field: 'actions', align: 'right' }
        ])

        // 状态过滤项：只发后端认识的取值，'' = 不带 state 参数（全部）。
        const stateOptions = computed(() => [
          { label: t.value.allStates, value: '' },
          { label: 'active', value: 'active' },
          { label: 'expired', value: 'expired' },
          { label: 'pending_delete', value: 'pending_delete' },
          { label: 'failed', value: 'failed' }
        ])

        const loadedText = computed(() => fill(t.value.loadedCount, {
          n: uploads.value.length, total: uploadTotal.value
        }))
        const canLoadMore = computed(() => uploads.value.length > 0 && uploads.value.length < uploadTotal.value)

        // 编辑时 secret 的占位/提示文案按 has_secret 区分（后端永不回显明文）。
        const secretPlaceholder = computed(() => (editingId.value && formDraft.has_secret ? t.value.secret : ''))
        const secretHint = computed(() => {
          if (!editingId.value) return t.value.secretNewHint
          return formDraft.has_secret ? t.value.secretKeepHint : t.value.secretNewHint
        })
        const isPlainHttp = computed(() => /^http:\/\//i.test(String(form.endpoint || '')))

        function isOn (value) {
          return value === 1 || value === true || value === '1'
        }

        function fill (text, values) {
          let out = String(text || '')
          for (const key of Object.keys(values || {})) {
            out = out.split('{' + key + '}').join(String(values[key]))
          }
          return out
        }

        function notify (type, message, timeout) {
          Quasar.Notify.create({ type, message, position: 'top-right', timeout: timeout || 2600 })
        }

        function formatDate (timestamp) {
          if (!timestamp) return t.value.noValue
          return new Intl.DateTimeFormat(locale.value, {
            year: 'numeric', month: '2-digit', day: '2-digit',
            hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
          }).format(new Date(timestamp * 1000))
        }

        function sizeText (value) {
          const bytes = Number(value)
          if (!Number.isFinite(bytes) || bytes < 0) return t.value.noValue
          const units = ['B', 'KB', 'MB', 'GB', 'TB']
          let size = bytes
          let index = 0
          while (size >= 1024 && index < units.length - 1) {
            size /= 1024
            index += 1
          }
          return (index === 0 ? String(size) : size.toFixed(size < 10 ? 1 : 0)) + ' ' + units[index]
        }

        function scopeText (row) {
          const roots = Array.isArray(row.writable_roots) && row.writable_roots.length
            ? row.writable_roots.filter(Boolean)
            : String(row.writable_paths || '').split(',').map(item => item.trim()).filter(Boolean)
          if (!roots.length) return t.value.writableAll
          return roots.join(', ')
        }

        function expiresText (hours) {
          const value = Number(hours)
          if (!Number.isFinite(value) || value <= 0) return t.value.expiresNever
          return t.value.hoursUnit.replace('%s', String(value))
        }

        // 剩余有效时间：expires_at 空/0 = 永不过期，已过期 = 待清理，否则换算时分。
        function expiryText (row) {
          const expiresAt = Number(row.expires_at)
          if (!Number.isFinite(expiresAt) || expiresAt <= 0) return t.value.expiresNever
          const left = expiresAt * 1000 - now.value
          if (left <= 0) return t.value.expiredPending
          const totalMinutes = Math.floor(left / 60000)
          return t.value.remaining
            .replace('%s', String(Math.floor(totalMinutes / 60)))
            .replace('%s', String(totalMinutes % 60))
        }

        function stateColor (state) {
          if (state === 'active') return 'teal-4'
          if (state === 'expired') return 'orange-8'
          if (state === 'failed' || state === 'pending_delete') return 'red-4'
          return 'grey-6'
        }

        function cfgName (id) {
          if (id === null || id === undefined || id === '') return t.value.noValue
          const hit = configs.value.find(row => String(row.id) === String(id))
          return hit ? hit.name : String(id)
        }

        async function load () {
          loading.value = true
          error.value = ''
          try {
            const [session, payload] = await Promise.all([
              window.adminApi.session(), window.adminApi.s3Configs()
            ])
            csrf.value = session.csrf || ''
            configs.value = payload.items || []
          } catch (err) {
            error.value = t.value.loadError + '：' + err.message
          } finally {
            loading.value = false
          }
        }

        // 拉一页上传记录：offset=0 覆盖列表，>0 追加（加载更多）。
        async function fetchUploads (offset, limit) {
          uploadsLoading.value = true
          try {
            const payload = await window.adminApi.listUploads({
              state: uploadState.value, limit: limit, offset: offset
            })
            const rows = payload.items || []
            uploads.value = offset ? uploads.value.concat(rows) : rows
            uploadTotal.value = Number(payload.total || 0)
          } catch (err) {
            notify('negative', t.value.uploadsLoadError + '：' + err.message)
          } finally {
            uploadsLoading.value = false
          }
        }

        // reset=true 回到第一页，false 追加下一页（加载更多）。
        function loadUploads (reset) {
          return fetchUploads(reset ? 0 : uploads.value.length, UPLOAD_PAGE)
        }

        // 删除单行后按「当前已加载窗口」重取（offset 0、limit 取当前条数）：
        // 直接追加下一页会让被删的行残留在表里，回到第一页又会丢掉已翻页的上下文。
        function refreshUploadsWindow () {
          return fetchUploads(0, Math.max(UPLOAD_PAGE, uploads.value.length))
        }

        function reloadUploads () {
          return loadUploads(true)
        }

        function loadMoreUploads () {
          return loadUploads(false)
        }

        function openCreate () {
          editingId.value = 0
          revealSecret.value = false
          Object.assign(form, emptyForm())
          Object.assign(formDraft, { virtual: false, has_secret: false, share_prefix: '' })
          formOpen.value = true
        }

        function openEdit (row) {
          if (row.virtual) {
            notify('warning', t.value.envHint)
            return
          }
          editingId.value = row.id
          revealSecret.value = false
          Object.assign(form, emptyForm(), {
            name: row.name || '',
            endpoint: row.endpoint || '',
            region: row.region || '',
            access_key_id: '',
            secret_access_key: '',
            // 后端存逗号分隔串，表单按行拆开；保存时再合并回逗号。
            writable_paths: (Array.isArray(row.writable_roots) ? row.writable_roots : String(row.writable_paths || '').split(','))
              .map(item => String(item).trim()).filter(Boolean).join('\n'),
            share_root: row.share_root || '',
            share_bucket: row.share_bucket || '',
            expires_hours: Number(row.expires_hours) || 0,
            use_bucket_lifecycle: isOn(row.use_bucket_lifecycle),
            default_bucket: row.default_bucket || '',
            allow_http: isOn(row.allow_http),
            enabled: isOn(row.enabled),
            note: row.note || ''
          })
          Object.assign(formDraft, {
            virtual: Boolean(row.virtual),
            has_secret: isOn(row.has_secret),
            share_prefix: row.share_prefix || ''
          })
          formOpen.value = true
        }

        function required (value) {
          return String(value === undefined || value === null ? '' : value).trim() !== '' || t.value.required
        }

        function validName (value) {
          return /^[a-z0-9_-]{1,32}$/.test(String(value || '')) || t.value.nameRule
        }

        // endpoint：必须以 http(s):// 开头，且不允许 path / ? / #。
        // 末尾单个斜杠按「无 path」放行并在提交时去掉，避免用户粘贴时踩无谓的错。
        function validEndpoint (value) {
          const text = String(value || '')
          return /^https?:\/\/[^/?#\s]+\/?$/.test(text) || t.value.endpointRule
        }

        function endpointPayload (value) {
          return String(value || '').replace(/\/+$/, '')
        }

        function requiredAkid (value) {
          if (editingId.value) return true
          return required(value) === true || t.value.akidRule
        }

        function requiredSecret (value) {
          if (editingId.value) return true
          return required(value) === true || t.value.secretRule
        }

        function validExpiresHours (value) {
          const num = Number(value)
          return (Number.isInteger(num) && num >= 0 && num <= 720) || t.value.expiresRule
        }

        function writablePathsPayload (text) {
          return String(text || '').split('\n').map(line => line.trim()).filter(Boolean).join(',')
        }

        function formPayload () {
          const payload = {
            endpoint: endpointPayload(form.endpoint),
            region: String(form.region || '').trim(),
            allow_http: Boolean(form.allow_http),
            writable_paths: writablePathsPayload(form.writable_paths),
            share_root: String(form.share_root || '').trim(),
            share_bucket: String(form.share_bucket || '').trim(),
            expires_hours: Number(form.expires_hours),
            use_bucket_lifecycle: Boolean(form.use_bucket_lifecycle),
            default_bucket: String(form.default_bucket || '').trim(),
            enabled: Boolean(form.enabled),
            note: String(form.note || '').trim()
          }
          // 凭证只填了才发：PATCH 语义是「空 = 不修改」，多发空串会把已存值清掉。
          const akid = String(form.access_key_id || '').trim()
          const secret = String(form.secret_access_key || '').trim()
          if (akid) payload.access_key_id = akid
          if (secret) payload.secret_access_key = secret
          if (!editingId.value) payload.name = String(form.name || '').trim()
          return payload
        }

        async function saveForm () {
          saving.value = true
          try {
            if (editingId.value) {
              await window.adminApi.updateS3Config({
                _csrf: csrf.value, id: editingId.value, ...formPayload()
              })
              notify('positive', t.value.updated)
            } else {
              await window.adminApi.createS3Config({
                _csrf: csrf.value, ...formPayload()
              })
              notify('positive', t.value.created)
            }
            formOpen.value = false
            await load()
          } catch (err) {
            // 后端的 message 原样透出，不吞异常。
            notify('negative', t.value.failed + '：' + err.message, 0)
          } finally {
            saving.value = false
          }
        }

        async function testCfg (row) {
          busy.test = row.id
          try {
            const result = await window.adminApi.testS3Config({ _csrf: csrf.value, id: row.id })
            const buckets = Array.isArray(result?.buckets) ? result.buckets : []
            notify('positive', t.value.testOk + ' · ' + fill(t.value.testBuckets, { n: buckets.length }))
          } catch (err) {
            notify('negative', t.value.testFailed + '：' + err.message, 0)
          } finally {
            busy.test = 0
          }
        }

        async function setDefault (row) {
          busy.default = row.id
          try {
            await window.adminApi.setDefaultS3Config({ _csrf: csrf.value, id: row.id })
            notify('positive', t.value.defaultDone)
            await load()
          } catch (err) {
            notify('negative', t.value.failed + '：' + err.message, 0)
          } finally {
            busy.default = 0
          }
        }

        async function toggleEnabled (row, next) {
          busy.enabled = row.id
          try {
            await window.adminApi.updateS3Config({ _csrf: csrf.value, id: row.id, enabled: Boolean(next) })
            notify('positive', next ? t.value.enabledDone : t.value.disabledDone)
            await load()
          } catch (err) {
            notify('negative', t.value.failed + '：' + err.message, 0)
            await load()
          } finally {
            busy.enabled = 0
          }
        }

        function removeCfg (row) {
          if (row.virtual) {
            notify('warning', t.value.envHint)
            return
          }
          Quasar.Dialog.create({
            title: t.value.deleteTitle,
            message: t.value.deleteConfirm.replace('%s', row.name),
            cancel: true,
            persistent: true,
            ok: { label: t.value.deleteAction, color: 'negative', flat: true }
          }).onOk(async () => {
            try {
              await window.adminApi.deleteS3Config({ _csrf: csrf.value, id: row.id })
              notify('positive', t.value.deleted)
              await load()
            } catch (err) {
              notify('negative', t.value.failed + '：' + err.message, 0)
            }
          })
        }

        function removeUpload (row) {
          Quasar.Dialog.create({
            title: t.value.deleteUploadTitle,
            message: t.value.deleteUploadConfirm,
            cancel: true,
            persistent: true,
            ok: { label: t.value.deleteUpload, color: 'negative', flat: true }
          }).onOk(async () => {
            busy.upload = row.id
            try {
              await window.adminApi.deleteUpload({ _csrf: csrf.value, id: row.id })
              notify('positive', t.value.uploadDeleted)
              await refreshUploadsWindow()
            } catch (err) {
              notify('negative', t.value.failed + '：' + err.message, 0)
            } finally {
              busy.upload = 0
            }
          })
        }

        async function runCleanup () {
          busy.cleanup = 1
          try {
            const result = await window.adminApi.cleanupUploads({ _csrf: csrf.value })
            notify('positive', fill(t.value.cleanupDone, {
              scanned: result?.scanned ?? 0,
              deleted: result?.deleted ?? 0,
              failed: result?.failed ?? 0,
              skipped: result?.skipped ?? 0
            }), 5000)
            await loadUploads(true)
          } catch (err) {
            notify('negative', t.value.failed + '：' + err.message, 0)
          } finally {
            busy.cleanup = 0
          }
        }

        function applyLocale (next) {
          locale.value = next
          document.documentElement.lang = next
          if (!props.showBack) document.title = t.value.title
          Quasar.Lang.set(next === 'zh-CN' ? Quasar.Lang.zhCN : Quasar.Lang.enUS)
        }

        // 自动刷新开关：只在打开时挂定时器，关掉立刻清理。
        watch(autoRefresh, next => {
          window.clearInterval(refreshTimer)
          refreshTimer = null
          if (next) refreshTimer = window.setInterval(reloadUploads, AUTO_REFRESH_MS)
        })

        onMounted(() => {
          applyLocale(locale.value)
          unsubscribeLocale = window.adminI18n.subscribe(applyLocale)
          tickTimer = window.setInterval(() => { now.value = Date.now() }, 60000)
          if (autoRefresh.value) refreshTimer = window.setInterval(reloadUploads, AUTO_REFRESH_MS)
          load()
          reloadUploads()
        })

        onBeforeUnmount(() => {
          unsubscribeLocale?.()
          window.clearInterval(refreshTimer)
          window.clearInterval(tickTimer)
        })

        return {
          autoRefresh, busy, canLoadMore, cfgName, columns, configs, editingId,
          error, expiryText, expiresText, filter, form, formDraft, formOpen, formatDate, isPlainHttp,
          loadedText, load, loadMoreUploads, loading, openCreate, openEdit, removeCfg,
          removeUpload, reloadUploads, required, requiredAkid, requiredSecret, revealSecret, runCleanup,
          saving, saveForm, scopeText, secretHint, secretPlaceholder, setDefault, sizeText, stateColor, isOn,
          stateOptions, t, testCfg, toggleEnabled, uploadColumns, uploadState, uploads, uploadsLoading,
          validEndpoint, validExpiresHours, validName
        }
    }
  }

  window.authzS3Configs = { component }
})()
