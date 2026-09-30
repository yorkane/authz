// 文件浏览器共享组件：files.html 与 s3.html 共用同一份交互逻辑。
// 页面只负责提供 adapter（接口差异）与页面外壳；本文件不 import 任何新依赖，
// 复用页面已加载的 window.Vue / window.Quasar / window.adminApi / window.adminI18n。
//
// 模板说明：quasar-umd.js 内置的 Vue 是带编译器的完整构建（含 Vue.compile），
// 所以这里直接用 template 字符串 + 渲染函数；组件自身状态经 defineExpose
// 暴露给宿主页面的插槽函数（如 S3 的桶选择器）。
(function () {
  'use strict'

  const IMAGES = ['jpg','jpeg','png','gif','webp','svg','bmp','ico','avif']
  const VIDEOS = ['mp4','webm','mov','m4v','mkv','ogv','avi']
  const AUDIOS = ['mp3','wav','ogg','oga','m4a','flac','aac','opus','weba','mka','aiff','aif','wma','amr','3gp']
  const TEXTS = ['txt','md','json','js','mjs','css','xml','log','csv','tsv','yml','yaml','ini','conf','lua','py','sh','sql']
  const MAX_TEXT_PREVIEW = 512 * 1024
  // 预览区底部原生控件条的高度估算：条内点按/拖拽交给原生进度条与音量。
  const CONTROL_STRIP = 72

  function extOf (name) {
    const base = name.split('/').pop()
    const dot = base.lastIndexOf('.')
    return dot >= 0 ? base.slice(dot + 1).toLowerCase() : ''
  }

  // 顶层版 kindOf（与组件内实现同表）：供宿主页在模板/脚本里判断扩展类型。
  function kindOf (item) {
    if (!item) return 'other'
    if (item.type === 'dir') return 'dir'
    const ext = extOf(item.name)
    if (IMAGES.includes(ext)) return 'image'
    if (VIDEOS.includes(ext)) return 'video'
    if (AUDIOS.includes(ext)) return 'audio'
    if (ext === 'html' || ext === 'htm') return 'html'
    if (TEXTS.includes(ext)) return 'text'
    return 'other'
  }

  // 文案合并：组件通用文案（browser 块）打底，页面自己的 i18nRoot 块覆盖同名键。
  // 这样 files 与 s3 可以各自定制标题/空态，而共享的「删除/重命名/上传」等
  // 文案统一维护在 browser 块，不重复。
  function mergedMessages (locale, pageBlock) {
    const all = window.adminI18n.messages[locale]
    return Object.assign({}, all.browser || {}, pageBlock || {})
  }

  const browserTemplate = `
<div class="az-browser" :class="'az-' + adapter.storagePrefix">
  <header class="page-heading az-browser-heading">
    <div>
      <h1>{{ t.title }}</h1>
      <p>{{ t.description }}</p>
    </div>
    <div class="files-toolbar">
      <slot name="toolbar-extra"></slot>
      <q-input v-model="filter" dense outlined clearable :placeholder="t.search" class="files-search" @update:model-value="focusFirst">
        <template v-slot:append><q-icon name="mdi-magnify"></q-icon></template>
      </q-input>
      <q-btn-toggle v-model="viewMode" dense unelevated no-caps :options="viewOptions" toggle-class="files-toggle-active"></q-btn-toggle>
      <q-btn dense unelevated round :icon="sortDesc ? 'mdi-sort-descending' : 'mdi-sort-ascending'" :title="t.sortOrder" @click="toggleSortOrder"></q-btn>
      <q-btn dense unelevated round icon="mdi-refresh" :title="t.refresh" @click="load"></q-btn>
      <q-btn v-if="adapter.supportsMkdir && dirWritable" dense unelevated no-caps icon="mdi-create-folder-outline" :label="t.newFolder" @click="startMkdir"></q-btn>
      <q-btn v-if="dirWritable" dense unelevated no-caps icon="mdi-upload" color="primary" :label="t.upload" :loading="uploading" @click="pickFiles"></q-btn>
      <input ref="fileInput" type="file" multiple class="files-upload-input" @change="onPickFiles">
    </div>
  </header>

  <div v-if="selectionCount" class="files-selection-bar">
    <q-btn flat dense no-caps icon="mdi-close" :label="t.clearSelection" @click="clearSelection"></q-btn>
    <span class="selection-count">{{ selectionText }}</span>
    <q-space></q-space>
    <q-btn flat dense no-caps icon="mdi-download" :label="t.download" @click="downloadSelection"></q-btn>
    <q-btn v-if="adapter.move" flat dense no-caps icon="mdi-drive-move-outline" :label="t.move" :disable="!selectedWritableCount" @click="askMoveSelected"></q-btn>
    <q-btn flat dense no-caps color="negative" icon="mdi-trash-can-outline" :label="t.delete" :disable="!selectedWritableCount" @click="askRemoveSelected"></q-btn>
  </div>

  <nav class="files-crumbs">
    <slot name="crumbs" :crumbs="crumbs"></slot>
    <q-space></q-space>
    <span class="files-stat">{{ statText }}</span>
  </nav>

  <q-banner v-if="error" rounded class="error-banner q-mb-md">
    <template v-slot:avatar><q-icon name="mdi-alert-circle-outline"></q-icon></template>
    {{ error }}
    <template v-slot:action><q-btn flat dense no-caps :label="t.retry" @click="load"></q-btn></template>
  </q-banner>
  <q-banner v-if="!dirWritable" rounded class="q-mb-md" dense>
    <template v-slot:avatar><q-icon name="mdi-lock-outline"></q-icon></template>
    {{ t.readOnlyDir }}
  </q-banner>
  <q-banner v-if="truncated" rounded class="q-mb-md" dense>
    <template v-slot:avatar><q-icon name="mdi-information-outline"></q-icon></template>
    {{ t.truncated }}
  </q-banner>

  <div v-if="loading" class="files-loading"><q-linear-progress indeterminate></q-linear-progress></div>

  <div v-if="dragging" class="files-drop-overlay">
    <div>
      <q-icon name="mdi-cloud-upload-outline" size="46px"></q-icon>
      <div>{{ t.dropHint }}</div>
      <div class="files-drop-path">{{ currentLocationText }}</div>
    </div>
  </div>
  <div v-if="uploading" class="files-uploading"><q-linear-progress indeterminate color="primary"></q-linear-progress><span>{{ uploadingText }}</span></div>

  <div v-if="viewMode === 'grid'" ref="grid" class="files-grid">
    <div v-for="(item, idx) in shown" :key="item.name" :id="'fx-' + idx" class="files-card" :class="{ 'files-focused': idx === focusIndex, 'files-selected': isSelected(item.name) }" tabindex="-1"
         @click="onItemClick(item, idx, $event)" @dblclick="onItemDouble(item)">
      <span class="card-select" @click.stop><q-checkbox :model-value="isSelected(item.name)" @click.stop @update:model-value="toggleSelect(idx)"></q-checkbox></span>
      <div v-if="itemWritable(item)" class="card-action-group">
        <q-btn flat dense round size="sm" icon="mdi-rename-box-outline" :aria-label="t.rename" @click.stop="startRename(item)"></q-btn>
        <q-btn flat dense round size="sm" icon="mdi-trash-can-outline" color="negative" :aria-label="t.delete" @click.stop="askRemove(item)"></q-btn>
      </div>
      <div class="files-thumb">
        <img v-if="kindOf(item) === 'image'" :src="fileUrl(item)" loading="lazy" decoding="async" alt="" @error="broken[idx] = true" v-show="!broken[idx]">
        <q-icon v-else :name="iconOf(item)" :color="colorOf(item)" :size="item.type === 'dir' ? '44px' : '38px'"></q-icon>
      </div>
      <div class="files-name" :title="item.name">{{ item.name }}<q-icon v-if="!itemWritable(item)" name="mdi-lock" size="14px" color="grey" class="q-ml-xs"></q-icon></div>
      <div class="files-meta">{{ item.type === 'dir' ? t.folder : sizeText(item.size) }}</div>
    </div>
  </div>

  <div v-else class="files-list" :class="{ 'preview-collapsed': !previewPanelOpen }">
    <div class="files-rows">
      <div class="files-row files-row-head">
        <span class="col-select" @click.stop><q-checkbox :model-value="headerSelectState" indeterminate-value="mixed" :disable="!shown.length" @update:model-value="onHeaderSelect"></q-checkbox></span>
        <span class="col-name files-sortable" @click="sortBy('name')" :title="t.sortName">{{ t.name }}<q-icon v-if="sortKey === 'name'" :name="sortDesc ? 'mdi-arrow-down': 'mdi-arrow-up'" size="14px" class="sort-caret"></q-icon></span><span class="col-size files-sortable" @click="sortBy('size')" :title="t.sortSize">{{ t.size }}<q-icon v-if="sortKey === 'size'" :name="sortDesc ? 'mdi-arrow-down': 'mdi-arrow-up'" size="14px" class="sort-caret"></q-icon></span><span class="col-date files-sortable" @click="sortBy('time')" :title="t.sortTime">{{ t.modified }}<q-icon v-if="sortKey === 'time'" :name="sortDesc ? 'mdi-arrow-down': 'mdi-arrow-up'" size="14px" class="sort-caret"></q-icon></span>
        <span class="col-action"></span>
      </div>
      <div v-for="(item, idx) in shown" :key="item.name" :id="'fx-' + idx" class="files-row" :class="{ 'files-focused': idx === focusIndex, 'files-selected': isSelected(item.name) }" tabindex="-1"
           @click="onItemClick(item, idx, $event)" @dblclick="onItemDouble(item)">
        <span class="col-select" @click.stop><q-checkbox :model-value="isSelected(item.name)" @click.stop @update:model-value="toggleSelect(idx)"></q-checkbox></span>
        <span class="col-name"><q-icon :name="iconOf(item)" :color="colorOf(item)" size="18px" class="q-mr-sm"></q-icon>{{ item.name }}<q-icon v-if="!itemWritable(item)" name="mdi-lock" size="14px" color="grey" class="q-ml-xs"></q-icon></span>
        <span class="col-size">{{ item.type === 'dir' ? '-' : sizeText(item.size) }}</span>
        <span class="col-date">{{ dateText(item.mtime) }}</span>
        <span class="col-action">
          <q-btn v-if="itemWritable(item)" flat dense round size="sm" icon="mdi-trash-can-outline" color="negative" :aria-label="t.delete" @click.stop="askRemove(item)"></q-btn>
          <q-btn flat dense round size="sm" icon="mdi-dots-vertical" :aria-label="t.actions" @click.stop>
            <q-menu auto-close>
              <q-list dense class="files-item-menu">
                <q-item v-if="item.type !== 'dir'" clickable v-close-popup @click="download(item)"><q-item-section side><q-icon name="mdi-download" size="18px"></q-icon></q-item-section><q-item-section>{{ t.download }}</q-item-section></q-item>
                <q-item v-if="adapter.shareUrl" clickable v-close-popup @click="share(item)"><q-item-section side><q-icon name="mdi-link-variant" size="18px"></q-icon></q-item-section><q-item-section>{{ t.share }}</q-item-section></q-item>
                <q-item v-for="action in (adapter.extraActions || [])" :key="action.label" clickable v-close-popup @click="action.onClick(item)"><q-item-section side><q-icon :name="action.icon || 'mdi-dots-vertical'" size="18px"></q-icon></q-item-section><q-item-section>{{ action.label }}</q-item-section></q-item>
                <q-item v-if="itemWritable(item)" clickable v-close-popup @click="startRename(item)"><q-item-section side><q-icon name="mdi-rename-box" size="18px"></q-icon></q-item-section><q-item-section>{{ t.rename }}</q-item-section></q-item>
                <q-separator></q-separator>
                <q-item v-if="itemWritable(item)" clickable v-close-popup class="menu-danger" @click="askRemove(item)"><q-item-section side><q-icon name="mdi-trash-can-outline" size="18px"></q-icon></q-item-section><q-item-section>{{ t.delete }}</q-item-section></q-item>
              </q-list>
            </q-menu>
          </q-btn>
        </span>
      </div>
      <div v-if="canLoadMore" class="az-more">
        <q-btn flat dense no-caps :label="t.loadMore" :loading="moreLoading" icon="mdi-tray-arrow-down" @click="loadMore"></q-btn>
      </div>
    </div>
    <aside v-if="previewPanelOpen && focused" class="files-detail">
      <div class="detail-title"><span class="detail-title-text"><q-icon :name="iconOf(focused)" :color="colorOf(focused)" class="q-mr-sm"></q-icon>{{ focused.name }}</span><q-btn flat dense round icon="mdi-arrow-collapse-right" :title="t.collapsePreview" @click="previewPanelOpen = false"></q-btn></div>
      <div class="detail-body">
        <img v-if="kindOf(focused) === 'image'" :src="fileUrl(focused)" alt="" class="detail-media">
        <video v-else-if="kindOf(focused) === 'video'" :src="fileUrl(focused)" controls preload="none" class="detail-media"></video>
        <audio v-else-if="kindOf(focused) === 'audio'" :src="fileUrl(focused)" controls preload="metadata" class="detail-audio"></audio>
        <iframe v-else-if="kindOf(focused) === 'html'" :src="fileUrl(focused, true)" class="detail-frame" sandbox="allow-scripts allow-forms allow-popups allow-modals"></iframe>
        <pre v-else-if="detailText !== null" class="detail-text">{{ detailText }}</pre>
        <div v-else class="detail-none"><q-icon name="mdi-file-outline" size="52px"></q-icon><div>{{ t.noPreview }}</div></div>
      </div>
      <div class="detail-meta">
        <span>{{ focused.type === 'dir' ? t.folder : sizeText(focused.size) }}</span>
        <span>{{ dateText(focused.mtime) }}</span>
        <q-btn flat dense no-caps icon="mdi-content-copy" :label="t.copyPath" @click="copyPath(focused)"></q-btn>
        <q-btn flat dense no-caps icon="mdi-open-in-new" :label="t.openInTab" @click="openInTab(focused)"></q-btn>
        <q-btn v-if="focused.type !== 'dir'" flat dense no-caps icon="mdi-download" :label="t.download" @click="download(focused)"></q-btn>
        <q-btn v-if="focused.type !== 'dir' && adapter.shareUrl" flat dense no-caps icon="mdi-link-variant" :label="t.share" @click="share(focused)"></q-btn>
        <q-btn v-if="itemWritable(focused)" flat dense no-caps icon="mdi-rename-box" :label="t.rename" @click="startRename(focused)"></q-btn>
        <q-btn v-if="itemWritable(focused)" flat dense no-caps icon="mdi-trash-can-outline" color="negative" :label="t.delete" @click="askRemove(focused)"></q-btn>
      </div>
    </aside>
    <q-btn v-else class="preview-expand-btn" flat dense round icon="mdi-page-layout-sidebar-right" :title="t.expandPreview" @click="previewPanelOpen = true"></q-btn>
  </div>

  <div v-if="!loading && shown.length === 0" class="files-empty">
    <q-icon name="mdi-folder-outline" size="54px"></q-icon>
    <div>{{ filter ? t.emptyFilter : t.empty }}</div>
  </div>

  <div v-if="!loading && pageCount > 1" class="files-pager">
    <q-pagination v-model="page" :max="pageCount" :max-pages="7" direction-links boundary-links boundary-numbers></q-pagination>
    <q-select v-model="pageSize" dense outlined :options="pageSizeOptions" class="files-page-size" :label="t.perPage"></q-select>
  </div>

  <div class="files-kbd-hint">{{ t.kbdHint }}</div>

  <q-dialog v-if="adapter.supportsMkdir" v-model="mkdirOpen" persistent>
    <q-card class="files-dialog-card">
      <q-card-section class="text-h6">{{ t.newFolderTitle }}</q-card-section>
      <q-card-section>
        <div class="files-dialog-path">{{ currentLocationText }}</div>
        <q-input v-model.trim="mkdirForm.name" dark dense outlined autofocus :label="t.newName" :hint="t.newNameHint" @keyup.enter="confirmMkdir"></q-input>
      </q-card-section>
      <q-card-actions align="right"><q-btn flat dense no-caps :label="t.cancel" v-close-popup></q-btn><q-btn unelevated dense no-caps :label="t.confirm" color="primary" :loading="mutating" @click="confirmMkdir"></q-btn></q-card-actions>
    </q-card>
  </q-dialog>

  <q-dialog v-model="renameOpen">
    <q-card class="files-dialog-card">
      <q-card-section class="text-h6">{{ t.renameTitle }}</q-card-section>
      <q-card-section>
        <div class="files-dialog-path">{{ renameForm.path ? renameForm.path + '/' : '' }}{{ renameForm.name }}</div>
        <q-input v-model.trim="renameForm.new_name" dark dense outlined autofocus :label="t.newName" :hint="t.newNameHint" @keyup.enter="confirmRename"></q-input>
      </q-card-section>
      <q-card-actions align="right"><q-btn flat dense no-caps :label="t.cancel" v-close-popup></q-btn><q-btn unelevated dense no-caps :label="t.confirm" color="primary" :loading="mutating" @click="confirmRename"></q-btn></q-card-actions>
    </q-card>
  </q-dialog>

  <q-dialog v-model="removeOpen">
    <q-card class="files-dialog-card">
      <q-card-section class="text-h6">{{ t.deleteTitle }}</q-card-section>
      <q-card-section>
        <div class="files-dialog-path">{{ removeForm.path ? removeForm.path + '/' : '' }}{{ removeForm.name }}</div>
        <p class="files-dialog-copy">{{ removeForm.type === 'dir' ? t.deleteDirCopy : t.deleteFileCopy }}</p>
        <q-toggle v-if="removeForm.type === 'dir'" v-model="removeForm.recursive" dense color="negative" :label="t.deleteRecursive"></q-toggle>
      </q-card-section>
      <q-card-actions align="right"><q-btn flat dense no-caps :label="t.cancel" v-close-popup></q-btn><q-btn unelevated dense no-caps :label="t.confirm" color="negative" :loading="mutating" @click="confirmRemove"></q-btn></q-card-actions>
    </q-card>
  </q-dialog>

  <q-dialog v-model="removeSelectedOpen">
    <q-card class="files-dialog-card">
      <q-card-section class="text-h6">{{ t.batchDeleteTitle }}</q-card-section>
      <q-card-section>
        <div class="files-dialog-path">{{ selectionPathText }}</div>
        <p class="files-dialog-copy">{{ batchDeleteCopy }}</p>
        <q-toggle v-if="selectedHasDir" v-model="removeSelectedForm.recursive" dense color="negative" :label="t.deleteRecursive"></q-toggle>
      </q-card-section>
      <q-card-actions align="right"><q-btn flat dense no-caps :label="t.cancel" v-close-popup></q-btn><q-btn unelevated dense no-caps color="negative" :label="t.confirm" :loading="mutating" @click="confirmRemoveSelected"></q-btn></q-card-actions>
    </q-card>
  </q-dialog>

  <q-dialog v-model="moveSelectedOpen">
    <q-card class="files-dialog-card">
      <q-card-section class="text-h6">{{ t.moveTitle }}</q-card-section>
      <q-card-section>
        <div class="files-dialog-path">{{ selectionPathText }}</div>
        <p class="files-dialog-copy">{{ moveCopy }}</p>
        <q-input v-model.trim="moveSelectedForm.target" dark dense outlined autofocus use-hint :label="t.moveTarget" :placeholder="movePlaceholderText" :hint="t.moveTargetHint" @keyup.enter="confirmMoveSelected"></q-input>
        <div class="files-dialog-path q-mt-sm">{{ moveResolvedText }}</div>
      </q-card-section>
      <q-card-actions align="right"><q-btn flat dense no-caps :label="t.cancel" v-close-popup></q-btn><q-btn unelevated dense no-caps color="primary" :label="t.confirm" :loading="mutating" @click="confirmMoveSelected"></q-btn></q-card-actions>
    </q-card>
  </q-dialog>

  <q-dialog v-model="previewOpen" maximized>
    <q-card class="files-preview-card">
      <q-card-section class="row items-center q-pb-none preview-head">
        <div class="text-h6 preview-title ellipsis"><q-icon :name="iconOf(previewItem)" :color="colorOf(previewItem)" class="q-mr-sm"></q-icon>{{ previewItem ? previewItem.name : '' }}</div>
        <span v-if="previewCount > 1" class="text-caption q-ml-sm preview-counter">{{ previewPosition }} / {{ previewCount }}</span>
        <q-space></q-space>
        <div class="preview-actions">
          <q-btn v-if="previewPosition > 1" flat dense round icon="mdi-chevron-left" :aria-label="t.prevFile" @click="stepPreview(-1)"></q-btn>
          <q-btn v-if="previewPosition < previewCount" flat dense round icon="mdi-chevron-right" :aria-label="t.nextFile" @click="stepPreview(1)"></q-btn>
          <q-btn v-if="previewItem" flat dense no-caps icon="mdi-content-copy" :label="isTouch ? '' : t.copyPath" :aria-label="t.copyPath" @click="copyPath(previewItem)"></q-btn>
          <q-btn v-if="previewItem" flat dense no-caps icon="mdi-open-in-new" :label="isTouch ? '' : t.openInTab" :aria-label="t.openInTab" @click="openInTab(previewItem)"></q-btn>
          <q-btn v-if="previewItem && previewItem.type !== 'dir'" flat dense no-caps icon="mdi-download" :label="isTouch ? '' : t.download" :aria-label="t.download" @click="download(previewItem)"></q-btn>
          <q-btn v-if="previewItem && previewItem.type !== 'dir' && adapter.shareUrl" flat dense no-caps icon="mdi-link-variant" :label="isTouch ? '' : t.share" :aria-label="t.share" @click="share(previewItem)"></q-btn>
          <q-btn dense round icon="mdi-close" color="primary" :flat="!isTouch" :unelevated="isTouch" :aria-label="t.close" @click="previewOpen = false"></q-btn>
        </div>
      </q-card-section>
      <q-card-section class="files-preview-body">
        <img v-if="previewKind === 'image'" :src="fileUrl(previewItem)" alt="" class="preview-image" :title="t.close"
          @click="onPreviewClick" @touchstart="onPreviewTouchStart" @touchend="onPreviewTouchEnd">
        <video v-else-if="previewKind === 'video'" :src="fileUrl(previewItem)" controls autoplay preload="metadata" class="preview-media"
          @touchstart.capture="onPreviewTouchStart" @touchend.capture="onPreviewTouchEnd"></video>
        <div v-else-if="previewKind === 'audio'" class="preview-audio-wrap" :title="t.playPause"
          @click="onPreviewClick" @touchstart="onPreviewTouchStart" @touchend="onPreviewTouchEnd"><q-icon name="mdi-music-circle-outline" size="84px"></q-icon><audio :src="fileUrl(previewItem)" controls preload="metadata" class="preview-audio"></audio></div>
        <iframe v-else-if="previewKind === 'html'" :src="fileUrl(previewItem, true)" class="preview-frame" sandbox="allow-scripts allow-forms allow-popups allow-modals"></iframe>
        <div v-else-if="previewKind === 'text'" class="preview-text-wrap"><pre v-if="previewText !== null">{{ previewText }}</pre><q-spinner v-else size="34px"></q-spinner></div>
        <div v-else class="preview-none">
          <q-icon name="mdi-file-outline" size="64px"></q-icon>
          <div class="q-mt-md">{{ t.noPreview }}</div>
          <q-btn class="q-mt-md" unelevated no-caps icon="mdi-download" :label="t.download" @click="download(previewItem)"></q-btn>
        </div>
      </q-card-section>
    </q-card>
  </q-dialog>
</div>
`
  const browserComponent = {
    name: 'AzBrowser',
    // 运行时编译：quasar-umd.js 的 Vue 带 compiler，template 字符串在页面加载时编译。
    template: browserTemplate,
    props: { adapter: { type: Object, required: true } },
    setup (props) {
      // 各页面的解构（const { ref } = Vue）只在自己的 script 作用域里；
      // 本组件在 IIFE 内定义，必须自己再从 window.Vue 取一遍。
      const { ref, reactive, computed, watch, nextTick, onMounted, onBeforeUnmount, defineExpose } = window.Vue
      const { adapter } = props
      const prefix = adapter.storagePrefix

      // ── i18n：browser 块（组件通用文案）打底，页面 i18nRoot 块覆盖同名键 ──
      const localeRef = ref(window.adminI18n.getLocale())
      const t = computed(() => mergedMessages(localeRef.value, window.adminI18n.messages[localeRef.value][adapter.i18nRoot] || {}))

      const loading = ref(false)
      const error = ref('')
      const path = ref(localStorage.getItem(prefix + '_path') || '')
      const items = ref([])
      const truncated = ref(false)
      // 只读门控：仅当 adapter.supportsWritable（S3 页）时启用；files 页恒可写，行为不变。
      // dirWritable 由 GET /api/s3（带 bucket）的 data.writable 决定，itemWritable 由 items[].writable 决定。
      const writableMode = computed(() => adapter.supportsWritable === true)
      const dirWritable = ref(true)
      function itemWritable (item) {
        if (!writableMode.value) return true
        return item && item.writable === true
      }
      // 服务端翻页 token（S3 用）：files 后端一次给全量，永远为 null。
      const nextToken = ref(null)
      const moreLoading = ref(false)
      const filter = ref('')
      const focusIndex = ref(0)
      // Backspace 返回上级时记下「刚离开的那一级目录」，新列表加载完成后把焦点
      // 落回它；消费一次立即清空，不污染普通刷新、翻页与过滤。
      let pendingFocusName = ''
      const broken = reactive({})

      // 多选：选中项按当前目录内的条目名记录（不是下标），排序、过滤、翻页
      // 或就地删除后仍指向同一批条目；anchorIdx 是 shift 连选的锚点。
      const selected = ref({})
      const anchorIdx = ref(null)
      const removeSelectedOpen = ref(false)
      const removeSelectedForm = reactive({ recursive: false })
      const moveSelectedOpen = ref(false)
      const moveSelectedForm = reactive({ target: '' })

      // 触屏设备没有可靠的双击语义：单击直接"打开/进入"，桌面仍是单击选中、双击打开。
      const isTouch = window.matchMedia && window.matchMedia('(pointer: coarse)').matches

      const page = ref(1)
      const pageSize = ref(Number(localStorage.getItem(prefix + '_page_size')) || 100)
      const pageSizeOptions = [50, 100, 200, 500]

      // 旧版有第三档 detail，合并进 list 后做一次性迁移。
      const savedView = localStorage.getItem(prefix + '_view')
      const viewMode = ref(savedView === 'detail' ? 'list' : (savedView || 'grid'))
      const sortKey = ref(localStorage.getItem(prefix + '_sort') || 'name')
      const sortDesc = ref(localStorage.getItem(prefix + '_sort_desc') === '1')
      const viewOptions = computed(() => [
        { value: 'grid', icon: 'mdi-view-grid-outline', label: '' },
        { value: 'list', icon: 'mdi-view-list-outline', label: '' }
      ])

      const previewOpen = ref(false)
      const previewItem = ref(null)
      const previewText = ref(null)
      const detailText = ref(null)
      const grid = ref(null)
      const fileInput = ref(null)
      // 列表视图预览面板的展开/收起；缩略图模式的图片预览由 img loading=lazy 按视口加载。
      const previewPanelOpen = ref(localStorage.getItem(prefix + '_preview_open') !== '0')

      function kindOf (item) {
        if (!item) return 'other'
        if (item.type === 'dir') return 'dir'
        const ext = extOf(item.name)
        if (IMAGES.includes(ext)) return 'image'
        if (VIDEOS.includes(ext)) return 'video'
        if (AUDIOS.includes(ext)) return 'audio'
        if (ext === 'html' || ext === 'htm') return 'html'
        if (TEXTS.includes(ext)) return 'text'
        return 'other'
      }

      function iconOf (item) {
        const kind = kindOf(item)
        return { dir: 'mdi-folder-outline', image: 'mdi-file-image-outline', video: 'mdi-file-video-outline',
                 audio: 'mdi-file-music-outline', html: 'mdi-language-html5', text: 'mdi-file-document-outline',
                 other: 'mdi-file-outline' }[kind]
      }

      // 按文件类别给图标着色（贴近文件管理器的颜色习惯）。
      const KIND_COLORS = { dir: 'amber-8', image: 'deep-orange-9', video: 'blue-6', audio: 'teal-6',
                            html: 'orange-7', text: 'green-6', other: 'grey-6' }
      function colorOf (item) {
        const kind = kindOf(item)
        if (kind === 'text') {
          // 文本类细分：CSS 绿色、JSON 黄色、Markdown/纯文本保持浅绿。
          const ext = extOf(item.name)
          if (ext === 'json') return 'yellow-8'
          if (ext === 'css') return 'green-6'
        }
        return KIND_COLORS[kind] || 'grey-6'
      }

      // 面包屑起点文案：files 是"根目录"，S3 是当前桶名（adapter.rootLabel 可为函数）。
      const rootLabel = computed(() => {
        const label = adapter.rootLabel
        if (typeof label === 'function') return label()
        return label || t.value.root
      })
      const currentLocationText = computed(() => path.value === '' ? rootLabel.value : path.value)

      // 对象字节 URL 完全交给 adapter（files → /_authz/files/...，S3 → /_authz/s3/<bucket>/...）。
      // preview 位带 ?authz_preview=1：nginx 对该请求注入 ESC 转发脚本
      // （沙箱 iframe 的按键不会冒泡到本页面，见 nginx.conf 的注入 map）。
      function fileUrl (item, preview, download) {
        if (!item) return ''
        return adapter.itemUrl(item, { preview: !!preview, download: !!download })
      }

      // 剪贴板：安全上下文走 Clipboard API；非安全上下文（http 直连 IP）
      // 回退到隐藏 textarea + execCommand。
      async function copyText (text) {
        if (navigator.clipboard && window.isSecureContext) {
          await navigator.clipboard.writeText(text)
          return
        }
        const ta = document.createElement('textarea')
        ta.value = text
        ta.style.position = 'fixed'
        ta.style.opacity = '0'
        document.body.appendChild(ta)
        ta.select()
        const ok = document.execCommand('copy')
        ta.remove()
        if (!ok) throw new Error('execCommand failed')
      }

      // 复制路径：files 是内容根绝对路径，S3 是对象 key，统一由 adapter.itemPath 给出。
      async function copyPath (item) {
        const text = adapter.itemPath ? adapter.itemPath(item) : ''
        try {
          await copyText(text)
          notify(t.value.copied + '：' + text, 'positive')
        } catch (err) {
          notify(t.value.copyFailed + '：' + text, 'negative')
        }
      }

      // 分享链接（S3）：调 adapter.shareUrl 拿 presigned URL，复制到剪贴板并提示。
      async function share (item) {
        if (!item || typeof adapter.shareUrl !== 'function') return
        try {
          const res = await adapter.shareUrl(item)
          const url = typeof res === 'string' ? res : (res && res.url) || ''
          if (!url) throw new Error('empty url')
          await copyText(url)
          notify(t.value.shared + '：' + url, 'positive')
        } catch (err) {
          notify(t.value.shareFailed + (err && err.message ? '：' + err.message : ''), 'negative')
        }
      }
      const previewKind = computed(() => previewItem.value ? kindOf(previewItem.value) : '')

      // 全屏预览的上一/下一个：沿用 filtered 的顺序（排序 + 过滤后的完整序列，
      // 跨分页连续），只跳过目录条目。
      const previewable = computed(() => filtered.value.filter(item => item.type !== 'dir'))
      const previewIndex = computed(() => previewItem.value
        ? previewable.value.findIndex(item => item.name === previewItem.value.name)
        : -1)
      const previewCount = computed(() => previewable.value.length)
      const previewPosition = computed(() => previewIndex.value + 1)

      function stepPreview (delta) {
        const list = previewable.value
        const next = previewIndex.value + delta
        if (next < 0 || next >= list.length) return
        const item = list[next]
        previewItem.value = item
        previewText.value = null
        if (kindOf(item) === 'text') {
          loadText(item).then(text => { previewText.value = text }).catch(() => { previewText.value = t.value.textTooLarge })
        }
        // 焦点与分页跟随预览项：关闭预览后列表停在同一文件上。
        // 页/焦点必须按 filtered（含目录）的位置换算，previewable 已剔除目录。
        const listIndex = filtered.value.findIndex(each => each.name === item.name)
        const targetPage = Math.floor(listIndex / pageSize.value) + 1
        if (targetPage !== page.value) page.value = targetPage
        focusIndex.value = listIndex - (targetPage - 1) * pageSize.value
        scrollFocusIntoView()
      }
      const focused = computed(() => shown.value[focusIndex.value] || null)

      // 预览区手势：图片沿用 light-box 习惯（点图即关）；视频/音频点画面切播放/暂停，
      // 但底部原生控件条（进度条、音量）内的点击让给控件本身；媒体上横向滑动切上一/下一个，
      // 音频控件与视频控件条内的横向拖拽留给原生 seek。
      let swipeState = null
      let tapGuarded = false
      // 刚打开预览的一小段时间内忽略预览区点击：移动端（尤其 iOS WKWebView）可能在
      // 触摸序列结束后延迟补发一个 click；此时列表项原位置已经渲染出预览图/视频，
      // 补发的 click 落在新元素上会被"点图即关"立刻关闭，表现为"单击打不开预览"。
      let previewOpenedAt = 0
      watch(previewOpen, value => {
        if (value) { previewOpenedAt = Date.now(); return }
        // 关闭预览时若仍处于本组件发起的全屏，一并退出；元素销毁时部分内核
        // 不会自动退出，会把黑屏留在整屏上。
        if (fullscreenRequested.value && (fullscreenEl() || document.webkitIsFullScreen)) exitFullscreen()
        fullscreenRequested.value = false
      })

      function inControlZone (el, y) {
        if (!el || !el.getBoundingClientRect) return false
        return y > el.getBoundingClientRect().bottom - CONTROL_STRIP
      }

      function mediaOf (el) {
        if (!el) return null
        if (el.tagName === 'VIDEO' || el.tagName === 'AUDIO') return el
        return el.querySelector('video, audio')
      }

      function toggleMedia (el) {
        const media = mediaOf(el)
        if (!media) return
        if (media.paused) {
          const result = media.play()
          if (result && typeof result.catch === 'function') result.catch(() => {})
        } else {
          media.pause()
        }
      }

      function onPreviewClick (event) {
        if (tapGuarded || Date.now() - previewOpenedAt < 800) return
        if (previewKind.value === 'image') { previewOpen.value = false; return }
        // 媒体（视频/音频）的触屏点按在 touchend 里处理：视频带 controls 时浏览器
        // 会抑制 click，且我们若与原生点击各切一次会正好抵消。这里只服务桌面鼠标。
        if (previewKind.value !== 'audio' || isTouch) return
        if (event.target.tagName === 'AUDIO') return
        toggleMedia(event.currentTarget)
      }

      function onPreviewTouchStart (event) {
        const touch = event.touches && event.touches[0]
        swipeState = touch
          ? { x: touch.clientX, y: touch.clientY, target: event.target, el: event.currentTarget, at: Date.now() }
          : null
      }

      function onPreviewTouchEnd (event) {
        const state = swipeState
        swipeState = null
        if (!state) return
        const touch = event.changedTouches && event.changedTouches[0]
        if (!touch) return
        const dx = touch.clientX - state.x
        const dy = touch.clientY - state.y
        // 触屏上带 controls 的媒体不会派发 click（浏览器把它留给控件），
        // 所以播放/暂停在这里按"位移很小 + 时间短"判定为点按。
        const kind = previewKind.value
        const isMediaTap = (kind === 'video' || kind === 'audio')
          && Math.abs(dx) < 12 && Math.abs(dy) < 12 && Date.now() - state.at < 500
        if (isMediaTap) {
          // 点在原生 <audio> 控件上、或视频底部控件条内：放行给原生（seek / 音量）。
          const onNative = state.target.tagName === 'AUDIO' || inControlZone(state.el, state.y)
          if (!onNative && Date.now() - previewOpenedAt >= 800) {
            tapGuarded = true
            setTimeout(() => { tapGuarded = false }, 400)
            event.preventDefault()
            // capture 阶段阻断，避免原生控件与 toggleMedia 各切一次互相抵消。
            event.stopPropagation()
            toggleMedia(state.el)
          }
          return
        }
        // 只认明显的横向滑动：位移够长且明显比纵向占优，否则留给原生滚动/拖拽。
        if (Math.abs(dx) < 56 || Math.abs(dx) < Math.abs(dy) * 1.6) return
        if (previewCount.value < 2) return
        if (state.target.tagName === 'AUDIO' || state.target.tagName === 'VIDEO') return
        if (previewKind.value === 'video' && inControlZone(state.el, state.y)) return
        // 滑动落地后浏览器还会补一个 click（图片会被误判成"点击关闭"），这里吃掉它。
        tapGuarded = true
        setTimeout(() => { tapGuarded = false }, 500)
        event.preventDefault()
        stepPreview(dx < 0 ? 1 : -1)
      }

      function sizeText (bytes) {
        if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + ' GiB'
        if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + ' MiB'
        if (bytes >= 1024) return (bytes / 1024).toFixed(1) + ' KiB'
        return bytes + ' B'
      }

      function dateText (ts) {
        if (!ts) return '-'
        const d = new Date(ts * 1000)
        const p = n => String(n).padStart(2, '0')
        return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes())
      }

      const filtered = computed(() => {
        const needle = filter.value.trim().toLowerCase()
        let list = items.value
        if (needle) list = list.filter(item => item.name.toLowerCase().includes(needle))
        const key = sortKey.value
        const dir = sortDesc.value ? -1 : 1
        return [...list].sort((a, b) => {
          if ((a.type === 'dir') !== (b.type === 'dir')) return a.type === 'dir' ? -1 : 1
          let cmp = 0
          if (key === 'size') cmp = (a.size || 0) - (b.size || 0)
          else if (key === 'time') cmp = (a.mtime || 0) - (b.mtime || 0)
          if (cmp === 0) cmp = a.name.localeCompare(b.name, undefined, { numeric: true })
          return cmp * (key === 'name' ? dir : dir)
        })
      })

      const pageCount = computed(() => Math.max(1, Math.ceil(filtered.value.length / pageSize.value)))
      const shown = computed(() => {
        const start = (page.value - 1) * pageSize.value
        return filtered.value.slice(start, start + pageSize.value)
      })

      const statText = computed(() => {
        const src = filtered.value
        const dirs = src.filter(i => i.type === 'dir').length
        const bytes = src.reduce((acc, i) => acc + (i.size || 0), 0)
        let text = dirs + ' ' + t.value.foldersUnit + ' · ' + (src.length - dirs) + ' ' + t.value.filesUnit + ' · ' + sizeText(bytes)
        if (pageCount.value > 1) text += ' · ' + t.value.pageOf.replace('%s', page.value).replace('%n', pageCount.value)
        return text
      })

      const crumbs = computed(() => {
        const parts = path.value === '' ? [] : path.value.split('/')
        const list = [{ path: '', label: rootLabel.value, root: true, current: parts.length === 0, go: () => navigate('') }]
        let acc = ''
        parts.forEach((part, i) => {
          acc = acc === '' ? part : acc + '/' + part
          // 必须为每级固定 target：acc 在循环结束后是当前完整路径，
          // 直接闭包捕获 acc 会让所有层级都跳到当前目录（看起来点了没反应）。
          const target = acc
          list.push({ path: target, label: part, root: false, current: i === parts.length - 1, go: () => navigate(target) })
        })
        return list
      })

      // 服务端还有下一页（S3 用 next_token 续拉；files 后端永远 null）。
      const canLoadMore = computed(() => !!nextToken.value)

      async function load () {
        loading.value = true
        error.value = ''
        page.value = 1
        try {
          const data = await adapter.list(path.value)
          items.value = data.items || []
          truncated.value = !!data.truncated
          dirWritable.value = !writableMode.value || data.writable === true
          nextToken.value = data.next_token || null
          clearSelection()
          focusFirst()
          applyPendingFocus()
        } catch (err) {
          error.value = err.message || String(err)
          items.value = []
          nextToken.value = null
        } finally {
          loading.value = false
        }
      }

      // 追加一页（token 翻页）：只在列表视图底部按钮触发；
      // 拉不到新 token 就清掉，避免按钮残留。
      async function loadMore () {
        if (!nextToken.value || moreLoading.value) return
        moreLoading.value = true
        try {
          const data = await adapter.list(path.value, nextToken.value)
          const incoming = data.items || []
          const seen = new Set(items.value.map(item => item.name))
          for (const item of incoming) {
            if (!seen.has(item.name)) items.value.push(item)
          }
          truncated.value = !!data.truncated
          dirWritable.value = !writableMode.value || data.writable === true
          nextToken.value = data.next_token || null
          pruneSelection()
        } catch (err) {
          notify(err.message || String(err), 'negative')
        } finally {
          moreLoading.value = false
        }
      }

      function navigate (next) {
        path.value = next
        localStorage.setItem(prefix + '_path', next)
        filter.value = ''
        page.value = 1
        // 先清空旧目录条目：否则加载期间残留的媒体缩略图会用新 path
        // 重算 URL，产生一批 404 请求。
        items.value = []
        nextToken.value = null
        load()
      }

      // 普通单击 = 聚焦（触屏另加打开）；Ctrl/Cmd = 切换选中；Shift = 连选。
      // 复选框列用 @click.stop 单独处理，不进这里。
      function onItemClick (item, idx, event) {
        const mods = event || {}
        if (mods.ctrlKey || mods.metaKey) {
          toggleSelect(idx)
          return
        }
        if (mods.shiftKey) {
          rangeSelectTo(idx)
          if (event && event.preventDefault) event.preventDefault()
          return
        }
        select(idx)
        if (isTouch) open(item)
      }

      function onItemDouble (item) {
        if (!isTouch) open(item)
      }

      function select (idx) {
        focusIndex.value = idx
        anchorIdx.value = idx
        refreshDetailText()
      }

      function focusFirst () {
        focusIndex.value = 0
        scrollFocusIntoView()
      }

      function moveFocus (delta) {
        const count = shown.value.length
        if (count === 0) return
        const next = focusIndex.value + delta
        if (next < 0) {
          // 越过页首：翻到上一页并聚焦其末尾。
          if (page.value <= 1) return
          page.value -= 1
          nextTick(() => {
            focusIndex.value = Math.max(0, shown.value.length - 1)
            scrollFocusIntoView()
            refreshDetailText()
          })
          return
        }
        if (next >= count) {
          if (page.value >= pageCount.value) return
          page.value += 1
          nextTick(() => {
            focusIndex.value = 0
            scrollFocusIntoView()
            refreshDetailText()
          })
          return
        }
        focusIndex.value = next
        anchorIdx.value = selectionCount.value ? anchorIdx.value : next
        scrollFocusIntoView()
        refreshDetailText()
      }

      function gridColumns () {
        if (!grid.value) return 1
        const style = window.getComputedStyle(grid.value)
        return Math.max(1, style.gridTemplateColumns.split(' ').length)
      }

      function scrollFocusIntoView () {
        nextTick(() => {
          const el = document.getElementById('fx-' + focusIndex.value)
          if (el) el.scrollIntoView({ block: 'nearest', inline: 'nearest' })
        })
      }

      // 返回上级后把焦点定位到来源目录：按名称在 filtered 全序列里换算页码与下标
      // （含目录条目，与 stepPreview 同一套路）；跨页时先翻页再落焦。
      function applyPendingFocus () {
        const name = pendingFocusName
        pendingFocusName = ''
        if (!name) return
        const listIndex = filtered.value.findIndex(item => item.name === name)
        if (listIndex < 0) return
        const targetPage = Math.floor(listIndex / pageSize.value) + 1
        const idx = listIndex - (targetPage - 1) * pageSize.value
        if (targetPage !== page.value) page.value = targetPage
        focusIndex.value = idx
        anchorIdx.value = idx
        // page 的 watcher 会把焦点清零，且回调晚于本次赋值，所以在 nextTick 再落一次。
        nextTick(() => {
          focusIndex.value = idx
          anchorIdx.value = idx
          scrollFocusIntoView()
          refreshDetailText()
        })
      }

      // 预览浮层内按 f：视频（无视频则整个预览卡片）进入/退出全屏。
      // 标准浏览器走 requestFullscreen；iOS Safari 的 video 只认 webkitEnterFullscreen。
      function fullscreenEl () {
        return document.fullscreenElement || document.webkitFullscreenElement || null
      }
      // 本次全屏是否由本组件发起：只在这种情况下让 Esc 先退全屏，避免影响
      // 视频自身（如 iframe 预览）内部的全屏行为。
      const fullscreenRequested = ref(false)
      function enterFullscreen (el) {
        if (el.requestFullscreen) return el.requestFullscreen()
        if (el.webkitRequestFullscreen) return el.webkitRequestFullscreen()
        if (el.webkitEnterFullscreen) return el.webkitEnterFullscreen()
        return null
      }
      function exitFullscreen (media) {
        if (media && media.webkitDisplayingFullscreen && media.webkitExitFullscreen) return media.webkitExitFullscreen()
        if (document.exitFullscreen && document.fullscreenElement) return document.exitFullscreen()
        if (document.webkitExitFullscreen) return document.webkitExitFullscreen()
        return null
      }
      function toggleMediaFullscreen () {
        const card = document.querySelector('.files-preview-card')
        if (!card) return
        const media = card.querySelector('video')
        const target = media || card
        if (fullscreenEl() === target || (media && media.webkitDisplayingFullscreen)) {
          fullscreenRequested.value = false
          exitFullscreen(media)
          return
        }
        fullscreenRequested.value = true
        try {
          const ret = enterFullscreen(target)
          if (ret && ret.catch) ret.catch(err => { fullscreenRequested.value = false; notify(fullscreenFailedText(err), 'negative') })
        } catch (err) {
          fullscreenRequested.value = false
          notify(fullscreenFailedText(err), 'negative')
        }
      }
      function fullscreenFailedText (err) {
        return t.value.fullscreenFailed + (err && err.message ? '：' + err.message : '')
      }

      async function open (item) {
        if (!item) return
        if (item.type === 'dir') return navigate(path.value === '' ? item.name : path.value + '/' + item.name)
        const kind = kindOf(item)
        if (kind === 'text') {
          previewText.value = null
          previewItem.value = item
          previewOpen.value = true
          loadText(item).then(text => { previewText.value = text }).catch(() => { previewText.value = t.value.textTooLarge })
        } else {
          previewItem.value = item
          previewOpen.value = true
        }
      }

      // 文本预览截断 512KB：再大的正文拉下来也只会卡顿，不如提示下载。
      async function loadText (item) {
        if ((item.size || 0) > MAX_TEXT_PREVIEW) return t.value.textTooLarge
        const response = await fetch(fileUrl(item), { credentials: 'same-origin' })
        if (!response.ok) throw new Error('HTTP ' + response.status)
        return await response.text()
      }

      function loadDetailText (item) {
        detailText.value = null
        if (!item || kindOf(item) !== 'text') return
        loadText(item).then(text => { detailText.value = text }).catch(() => { detailText.value = t.value.textTooLarge })
      }

      // 面板收起或不在列表视图时不加载文本预览，避免白白拉正文。
      function refreshDetailText () {
        if (viewMode.value === 'list' && previewPanelOpen.value) loadDetailText(focused.value)
        else detailText.value = null
      }

      function openInTab (item) {
        if (!item) return
        window.open(fileUrl(item), '_blank', 'noopener')
      }

      // 下载走 adapter 的 download URL（files 靠 anchor.download 直接落盘；
      // S3 的字节 URL 带 ?download=1 由后端给 Content-Disposition attachment）。
      function download (item) {
        if (!item || item.type === 'dir') return
        if (adapter.itemUrl && adapter.itemUrl(item, { download: true })) {
          const anchor = document.createElement('a')
          anchor.href = adapter.itemUrl(item, { download: true })
          anchor.download = item.name
          anchor.click()
          return
        }
        window.open(fileUrl(item), '_blank', 'noopener')
      }

      // ── 写操作：上传 / 重命名 / 删除 ────────────────────────────────────
      // 全部走各自 adapter 的接口；上传用 multipart，前端只把 File 对象交给
      // FormData，不经 JSON、不读入内存字符串。CSRF token 启动时取一次缓存。
      const csrf = ref('')
      const uploading = ref(false)
      const uploadingText = ref('')
      const dragging = ref(false)
      const mutating = ref(false)
      const renameOpen = ref(false)
      const renameForm = reactive({ path: '', name: '', new_name: '' })
      const mkdirOpen = ref(false)
      const mkdirForm = reactive({ name: '' })
      const removeOpen = ref(false)
      const removeForm = reactive({ path: '', name: '', type: 'file', recursive: false })

      // timeout=0 表示常驻（批量操作的部分失败清单需要人读完再手动关）
      function notify (message, type, timeout) {
        Quasar.Notify.create({ message, type, position: 'top-right', timeout: timeout === undefined ? 2600 : timeout })
      }

      function pickFiles () {
        if (!dirWritable.value) return
        fileInput.value?.click()
      }

      function onPickFiles (event) {
        if (!dirWritable.value) {
          event.target.value = ''
          return
        }
        const filesPicked = Array.from(event.target.files || [])
        event.target.value = ''
        upload(filesPicked)
      }

      let dragTimer
      // dragleave 在指针跨过任意子元素时也会触发，会闪断遮罩：改用短超时，
      // dragover 每 200ms 续期一次，指针真正离开后遮罩自动消失。
      function dragHover () {
        dragging.value = true
        window.clearTimeout(dragTimer)
        dragTimer = window.setTimeout(() => { dragging.value = false }, 200)
      }

      function onDrop (event) {
        window.clearTimeout(dragTimer)
        dragging.value = false
        if (!dirWritable.value) return
        const filesDropped = Array.from(event.dataTransfer?.files || [])
        if (filesDropped.length) upload(filesDropped)
      }

      // 只对"携带文件"的拖拽生效，其余（选中文本、链接）保持浏览器原生行为。
      function hasFileDrag (event) {
        return Array.from(event.dataTransfer?.types || []).includes('Files')
      }

      function onWindowDragOver (event) {
        if (!hasFileDrag(event)) return
        if (!dirWritable.value) return
        event.preventDefault()
        dragHover()
      }

      function onWindowDrop (event) {
        if (!hasFileDrag(event)) return
        if (!dirWritable.value) return
        event.preventDefault()
        onDrop(event)
      }

      async function upload (filesPicked, overwrite) {
        if (!filesPicked.length) return
        if (!dirWritable.value) return
        uploading.value = true
        uploadingText.value = t.value.uploading.replace('{n}', String(filesPicked.length))
        try {
          const result = await adapter.upload(path.value, filesPicked, overwrite)
          const skipped = result?.skipped || []
          let doneMessage = t.value.uploaded.replace('{ok}', String((result?.uploaded || []).length))
          if (skipped.length) doneMessage += t.value.uploadedSkipped.replace('{skip}', String(skipped.length))
          notify(doneMessage, skipped.length ? 'warning' : 'positive')
          if (skipped.length) console.warn('upload skipped:', skipped)
          await load()
        } catch (err) {
          // 409 是同名冲突：确认后带 overwrite 重传，避免用户先去改名。
          if (err.status === 409 && !overwrite) {
            uploading.value = false
            Quasar.Dialog.create({
              title: t.value.overwriteTitle,
              message: t.value.overwriteCopy,
              cancel: true,
              persistent: true
            }).onOk(() => upload(filesPicked, true))
            return
          }
          notify(err.message || String(err), 'negative')
        } finally {
          uploading.value = false
          uploadingText.value = ''
        }
      }
      function startRename (item) {
        if (!item || !itemWritable(item)) return
        Object.assign(renameForm, { path: path.value, name: item.name, new_name: item.name })
        renameOpen.value = true
      }

      function startMkdir () {
        if (!dirWritable.value) return
        mkdirForm.name = ''
        mkdirOpen.value = true
      }

      async function confirmMkdir () {
        const name = mkdirForm.name.trim()
        if (!name) return
        mutating.value = true
        try {
          await adapter.mkdir(path.value, name)
          mkdirOpen.value = false
          notify(t.value.created, 'positive')
          await load()
        } catch (err) {
          notify(err.message || String(err), 'negative')
        } finally {
          mutating.value = false
        }
      }

      async function confirmRename () {
        const next = renameForm.new_name.trim()
        if (!next || next === renameForm.name) {
          notify(t.value.renameUnchanged, 'warning')
          return
        }
        mutating.value = true
        try {
          await adapter.rename(renameForm.path, renameForm.name, next)
          renameOpen.value = false
          notify(t.value.renamed, 'positive')
          await load()
        } catch (err) {
          notify(err.message || String(err), 'negative')
        } finally {
          mutating.value = false
        }
      }

      // ── 多选与批量操作 ────────────────────────────────────────────────
      function isSelected (name) {
        return selected.value[name] === true
      }

      function clearSelection () {
        selected.value = {}
        anchorIdx.value = null
      }

      // 名称 -> 条目名：选中集只保留仍存在于当前 items 的条目（翻页追加时
      // items 是累积的，因此已加载过的选中项不会被裁掉）。
      function pruneSelection () {
        const alive = {}
        for (const item of items.value) {
          if (selected.value[item.name] === true) alive[item.name] = true
        }
        selected.value = alive
      }

      function toggleSelect (idx) {
        const item = shown.value[idx]
        if (!item) return
        focusIndex.value = idx
        const next = Object.assign({}, selected.value)
        if (next[item.name]) delete next[item.name]
        else next[item.name] = true
        selected.value = next
        anchorIdx.value = idx
      }

      // shift 连选：把锚点到目标之间（shown 顺序）的条目全部纳入选中集；
      // 锚点保持不变，符合文件管理器的连续扩选语义。
      function rangeSelectTo (idx) {
        const anchor = anchorIdx.value === null ? focusIndex.value : anchorIdx.value
        const low = Math.min(anchor, idx)
        const high = Math.max(anchor, idx)
        const next = Object.assign({}, selected.value)
        for (let i = low; i <= high; i += 1) {
          const item = shown.value[i]
          if (item) next[item.name] = true
        }
        selected.value = next
        focusIndex.value = idx
        scrollFocusIntoView()
      }

      // 表头全选作用于全部已加载条目（S3 未加载的页需先「加载下一页」）。
      function selectAll (value) {
        if (!value) {
          clearSelection()
          return
        }
        const next = {}
        for (const item of items.value) next[item.name] = true
        selected.value = next
        anchorIdx.value = null
      }

      const selectedNames = computed(() => items.value.filter(item => selected.value[item.name] === true).map(item => item.name))
      const selectionCount = computed(() => selectedNames.value.length)
      const selectedWritableCount = computed(() => items.value
        .filter(item => selected.value[item.name] === true && itemWritable(item)).length)
      const selectedHasDir = computed(() => items.value
        .some(item => selected.value[item.name] === true && item.type === 'dir'))
      const allSelected = computed(() => items.value.length > 0 && selectionCount.value === items.value.length)
      const someSelected = computed(() => selectionCount.value > 0 && selectionCount.value < items.value.length)
      // Quasar UMD 的 QCheckbox 没有布尔 indeterminate 属性，三态只能靠
      // modelValue === indeterminateValue 表达；mixed 态下点击按默认切换序
      // 回到 trueValue，正好是「半选 -> 全选」的文件管理器语义。
      const headerSelectState = computed(() => {
        if (allSelected.value) return true
        return someSelected.value ? 'mixed' : false
      })

      function onHeaderSelect (value) {
        selectAll(value === true)
      }
      const selectionText = computed(() => t.value.selectedCount.replace('{n}', String(selectionCount.value)))
      const selectionPathText = computed(() => currentLocationText.value)
      const batchDeleteCopy = computed(() => t.value.batchDeleteCopy.replace('{n}', String(selectedWritableCount.value)))
      const moveCopy = computed(() => t.value.moveCopy.replace('{n}', String(selectedWritableCount.value)))
      // 实时把输入解析成最终目标目录回显，避免「输入 mvdst 结果搬到桶根/内容根」这类意外。
      const moveResolvedText = computed(() => {
        const target = normalizeMoveTarget(moveSelectedForm.target)
        if (target === '') return t.value.moveSameDir
        if (target.split('/').includes('..')) return t.value.moveBadTarget
        if (target === path.value) return t.value.moveSameDir
        return t.value.moveResolved.replace('{p}', target)
      })
      // 占位符给一个「当前目录下的子目录」示例，明示相对基准。
      const movePlaceholderText = computed(() => path.value === '' ? t.value.movePlaceholderRoot : t.value.movePlaceholderSub)

      // 逐个串行调用单条端点：任一失败不中断其余，最后汇总部分失败清单。
      // 失败项结构化保存 {name, message}——文件名可以含冒号，不能靠字符串分割回推。
      async function runBatch (names, worker) {
        mutating.value = true
        let ok = 0
        const failures = []
        try {
          for (const name of names) {
            try {
              await worker(name)
              ok += 1
            } catch (err) {
              failures.push({ name, message: err.message || String(err) })
            }
          }
        } finally {
          mutating.value = false
        }
        return { ok, failures }
      }

      // 汇总提示：前若干条失败原因直接可读，其余进 console。
      function reportBatch (result, successKey) {
        if (result.failures.length) {
          const detail = result.failures.slice(0, 3).map(f => f.name + ' - ' + f.message).join('; ')
          if (result.failures.length > 3) console.warn('batch failures', result.failures)
          // 部分失败要常驻（timeout 0）：原因里通常含 403/409 这类需要人去改配置的说明，
          // 2.6 秒自动消失等于没提示。
          notify(t.value.batchPartial
            .replace('{ok}', String(result.ok))
            .replace('{fail}', String(result.failures.length)) + ' · ' + detail, 'negative', 0)
        } else {
          notify(t.value[successKey].replace('{n}', String(result.ok)), 'positive')
        }
      }

      function askRemoveSelected () {
        if (!selectedWritableCount.value) return
        removeSelectedForm.recursive = selectedHasDir.value
        removeSelectedOpen.value = true
      }

      async function confirmRemoveSelected () {
        const names = selectedNames.value.filter(name => {
          const item = items.value.find(entry => entry.name === name)
          return item && itemWritable(item)
        })
        if (!names.length) return
        const target = path.value
        const recursive = removeSelectedForm.recursive
        const result = await runBatch(names, name => adapter.remove(target, name, recursive === true))
        // 成功项就地从列表移除，失败项留在原地并列出原因。
        const failed = new Set(result.failures.map(f => f.name))
        for (const name of names) {
          if (!failed.has(name)) removeItemLocal(name)
        }
        pruneSelection()
        removeSelectedOpen.value = false
        reportBatch(result, 'batchDeleted')
      }

      function askMoveSelected () {
        if (!adapter.move || !selectedWritableCount.value) return
        moveSelectedForm.target = ''
        moveSelectedOpen.value = true
      }

      // 目标目录解析（与服务端 new_path 的「相对内容根/桶」语义之间的桥）：
      //   输入以 / 开头 = 从内容根/桶根算起；否则按「当前目录的子目录」算起
      //   ——与所有文件管理器的直觉一致（S3 的 path 是深前缀时尤其重要：
      //   在 share/<ip>/ 下输入 mvdst 若按桶根解析会掉出可写范围，整批 403）。
      // 返回去掉首尾斜杠的完整相对路径；'' = 未移动；含 .. 段留给 confirm 拒绝。
      function normalizeMoveTarget (raw) {
        const clean = s => s.replace(/\\/g, '/').replace(/\/{2,}/g, '/').replace(/^\/+|\/+$/g, '')
        const input = String(raw || '').trim()
        if (input === '') return ''
        if (input.startsWith('/')) return clean(input)
        return clean((path.value ? path.value + '/' : '') + input)
      }

      async function confirmMoveSelected () {
        const target = normalizeMoveTarget(moveSelectedForm.target)
        if (target.split('/').includes('..')) {
          notify(t.value.moveBadTarget, 'negative')
          return
        }
        // 留空或解析后仍等于当前目录都算"没动"。
        if (target === '' || target === path.value) {
          notify(t.value.moveSameDir, 'negative')
          return
        }
        const names = selectedNames.value.filter(name => {
          const item = items.value.find(entry => entry.name === name)
          return item && itemWritable(item)
        })
        if (!names.length) return
        const source = path.value
        const result = await runBatch(names, name => adapter.move(source, name, target))
        // 目标目录不存在时逐条 404 也走部分失败清单；此处不再重复提示
        const failed = new Set(result.failures.map(f => f.name))
        for (const name of names) {
          if (!failed.has(name)) removeItemLocal(name)
        }
        pruneSelection()
        moveSelectedOpen.value = false
        reportBatch(result, 'batchMoved')
      }

      // 批量下载：逐个触发，数量设上限，避免一次抛出几十个下载任务。
      function downloadSelection () {
        const picked = items.value.filter(item => selected.value[item.name] === true && item.type !== 'dir')
        if (!picked.length) {
          notify(t.value.downloadNoFiles, 'negative')
          return
        }
        if (picked.length > 20) {
          notify(t.value.downloadTooMany.replace('{n}', String(picked.length)), 'negative')
          return
        }
        picked.forEach(download)
      }

      function askRemove (item, recursive) {
        if (!item || !itemWritable(item)) return
        Object.assign(removeForm, { path: path.value, name: item.name, type: item.type, recursive: !!recursive })
        removeOpen.value = true
      }

      async function confirmRemove () {
        mutating.value = true
        try {
          const recursive = removeForm.type === 'dir' ? removeForm.recursive : false
          await adapter.remove(removeForm.path, removeForm.name, recursive)
          removeOpen.value = false
          notify(t.value.deleted, 'positive')
          // 不做整页 reload：从本地列表就地移除该项，焦点留在原位，
          // 可以直接 Delete 连续删下一个；统计条随 computed 自动更新。
          removeItemLocal(removeForm.name)
        } catch (err) {
          notify(err.message || String(err), 'negative')
        } finally {
          mutating.value = false
        }
      }

      function removeItemLocal (name) {
        const wasFocused = focused.value && focused.value.name === name
        items.value = items.value.filter(item => item.name !== name)
        // 预览恰好停在被删项上：关掉，避免预览指向不存在的文件。
        if (previewItem.value && previewItem.value.name === name) {
          previewOpen.value = false
          previewItem.value = null
        }
        if (selected.value[name]) {
          const next = Object.assign({}, selected.value)
          delete next[name]
          selected.value = next
        }
        if (wasFocused) {
          // 焦点收敛到剩余项原位；shown/分页是 computed，随 items 收缩。
          focusIndex.value = Math.min(focusIndex.value, Math.max(0, shown.value.length - 1))
          nextTick(() => { scrollFocusIntoView(); refreshDetailText() })
        }
      }

      function toggleSortOrder () {
        sortDesc.value = !sortDesc.value
      }

      // 表头点击排序：同列切换升/降序，换列沿用当前方向。
      function sortBy (key) {
        if (sortKey.value === key) sortDesc.value = !sortDesc.value
        else sortKey.value = key
      }

      function handleKeydown (event) {
        const target = event.target
        // 删除确认框打开时：Enter 直接确认删除（preventDefault 同时抑制焦点按钮的
        // 原生激活，避免双重提交），ESC / 点遮罩取消由对话框自己处理；
        // 其余按键不下落到列表逻辑，防止隔框误触（Enter 打开、Delete 再弹框等）。
        if (removeOpen.value) {
          if (event.key === 'Enter' && !mutating.value) {
            confirmRemove()
            event.preventDefault()
          }
          return
        }
        if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) {
          // 搜索框内的 Enter 视为"打开当前选中项"，其余按键保持正常编辑。
          if (target.tagName === 'INPUT' && event.key === 'Enter' && !previewOpen.value) {
            target.blur()
            open(focused.value)
            event.preventDefault()
          }
          return
        }
        // 批量确认框打开时同样只吃 Enter/Esc，其余按键不落到列表逻辑。
        if (removeSelectedOpen.value || moveSelectedOpen.value) {
          if (event.key === 'Enter' && !mutating.value) {
            if (removeSelectedOpen.value) confirmRemoveSelected()
            else confirmMoveSelected()
            event.preventDefault()
          }
          return
        }
        if ((event.ctrlKey || event.metaKey) && (event.key === 'a' || event.key === 'A') && !previewOpen.value) {
          // 全选 / 取消全选（作用于全部已加载条目）
          selectAll(!allSelected.value)
          event.preventDefault()
          return
        }
        if (event.ctrlKey || event.metaKey || event.altKey) return
        if (previewOpen.value) {
          // 全屏预览中：左右键切换上一/下一个文件（按当前排序与过滤顺序）。
          // 焦点在媒体控件上时左右键留给快进/回退，不切文件。
          if (event.key === 'Escape') {
            // 本组件发起的全屏：第一次 Esc 只退全屏（浏览器原生行为，这里不重复调用，
            // 否则会与原生退出叠加把整层关掉），第二次 Esc 才关预览。
            // 覆盖层元素还在时不能直接关浮层：部分内核在全屏中会提前把 Esc 同时投递给
            // document，先由 onPreviewEscMessage 关掉浮层，再执行到这里会连按状态串味。
            previewOpen.value = false
          } else if (event.key === 'f' || event.key === 'F') {
            // 一律由本组件接管（preventDefault 顺带压掉 Safari 视频控件自带的 f），
            // 否则焦点在 video 上时会出现"按了没反应"或两套逻辑互相抵消。
            toggleMediaFullscreen()
            event.preventDefault()
          } else if ((event.key === 'ArrowRight' || event.key === 'ArrowLeft')
            && previewable.value.length > 1
            && !(target && (target.tagName === 'VIDEO' || target.tagName === 'AUDIO'))) {
            stepPreview(event.key === 'ArrowRight' ? 1 : -1)
            event.preventDefault()
          }
          return
        }
        // 无修饰键状态下才处理选择类快捷键（预览分支已在上面 return）。
        if (event.shiftKey && ['ArrowRight', 'ArrowLeft', 'ArrowDown', 'ArrowUp'].includes(event.key)) {
          // shift + 方向键：移动焦点的同时扩选（网格多列时按列宽跨行）。
          const cols = gridColumns()
          const delta = event.key === 'ArrowRight' ? 1
            : event.key === 'ArrowLeft' ? -1
              : event.key === 'ArrowDown' ? cols : -cols
          const next = focusIndex.value + delta
          if (next >= 0 && next < shown.value.length) rangeSelectTo(next)
          event.preventDefault()
          return
        }
        if (event.key === 'Escape' && selectionCount.value) {
          clearSelection()
          event.preventDefault()
          return
        }
        const cols = viewMode.value === 'grid' ? gridColumns() : 1
        switch (event.key) {
          case 'ArrowRight': moveFocus(1); break
          case 'ArrowLeft': moveFocus(-1); break
          case 'ArrowDown': moveFocus(cols); break
          case 'ArrowUp': moveFocus(-cols); break
          case 'Home': focusIndex.value = 0; scrollFocusIntoView(); break
          case 'End': focusIndex.value = shown.value.length - 1; scrollFocusIntoView(); break
          case 'PageDown': if (page.value < pageCount.value) page.value += 1; break
          case 'PageUp': if (page.value > 1) page.value -= 1; break
          case 'Enter': open(focused.value); break
          case 'Backspace':
            if (path.value !== '') {
              // 记住刚离开的那一级目录名：返回后焦点落回它，而不是列表第一行。
              const parts = path.value.split('/')
              pendingFocusName = parts[parts.length - 1]
              navigate(parts.slice(0, -1).join('/'))
            }
            break
          case 'Delete':
            // 有选中集时批量删除；否则删除当前焦点项（与列表行删除按钮同一
            // 确认对话框，目录需勾选递归）。只读条目不响应。
            if (selectedWritableCount.value) askRemoveSelected()
            else if (focused.value && itemWritable(focused.value)) askRemove(focused.value)
            break
          case 'g': viewMode.value = 'grid'; break
          case 'l': viewMode.value = 'list'; break
          case 'p': if (viewMode.value === 'list') previewPanelOpen.value = !previewPanelOpen.value; break
          case 'f': {
            const input = document.querySelector('.az-browser .files-search input')
            if (input) input.focus()
            break
          }
          default: return
        }
        event.preventDefault()
      }

      // 视图/排序/分页状态按各自 namespace 落 localStorage，两页互不干扰。
      watch(viewMode, value => { localStorage.setItem(prefix + '_view', value); refreshDetailText(); scrollFocusIntoView() })
      watch(previewPanelOpen, value => { localStorage.setItem(prefix + '_preview_open', value ? '1' : '0'); refreshDetailText() })
      watch(sortKey, value => localStorage.setItem(prefix + '_sort', value))
      watch(sortDesc, value => localStorage.setItem(prefix + '_sort_desc', value ? '1' : '0'))
      watch(pageSize, value => { localStorage.setItem(prefix + '_page_size', String(value)); page.value = 1 })
      watch(page, value => {
        if (value === 0) { page.value = 1; return }
        focusIndex.value = 0
        scrollFocusIntoView()
        refreshDetailText()
      })
      // 过滤/排序变化后页码与焦点可能失效，收敛后刷新详情预览。
      watch(filtered, () => {
        if (page.value > pageCount.value) page.value = pageCount.value
        if (focusIndex.value >= shown.value.length) focusIndex.value = Math.max(0, shown.value.length - 1)
        refreshDetailText()
        scrollFocusIntoView()
      })

      function applyLocale (nextLocale) {
        localeRef.value = nextLocale
        document.documentElement.lang = nextLocale
        document.title = t.value.title
        Quasar.Lang.set(nextLocale === 'zh-CN' ? Quasar.Lang.zhCN : Quasar.Lang.enUS)
      }
      function applyLocale (nextLocale) {
        localeRef.value = nextLocale
        document.documentElement.lang = nextLocale
        document.title = t.value.title
        Quasar.Lang.set(nextLocale === 'zh-CN' ? Quasar.Lang.zhCN : Quasar.Lang.enUS)
      }

      let unsubscribeLocale
      onMounted(() => {
        applyLocale(localeRef.value)
        unsubscribeLocale = window.adminI18n.subscribe(applyLocale)
        window.addEventListener('keydown', handleKeydown)
        // 沙箱 iframe 里被注入的 ESC 转发脚本（nginx sub_filter）把按键
        // postMessage 到这里，保证 html 预览也能用 ESC 关闭。来源不可信但
        // 消息类型是自定义的，误触概率可忽略。
        window.addEventListener('message', onPreviewEscMessage)
        document.addEventListener('keydown', onPreviewEscCapture, true)
        document.addEventListener('fullscreenchange', onFullscreenChange)
        document.addEventListener('webkitfullscreenchange', onFullscreenChange)
        // window 级拖放：只要落点在本页（iframe）内任何位置都能收进当前目录。
        // 只绑在 main 上时，落点在边距/滚动条/工具栏空隙，浏览器不拦截 drop，
        // 会把整个页面导航到被拖的文件。
        window.addEventListener('dragover', onWindowDragOver)
        window.addEventListener('drop', onWindowDrop)
        // 写操作（上传/重命名/删除）都要求 CSRF 头：启动时取一次会话缓存 token。
        // 取不到（例如以 API Key 打开本页）只是没有写权限，浏览照旧。
        window.adminApi.session().then(session => { csrf.value = session.csrf || '' }).catch(() => {})
        load()
      })
      // 全屏状态变化（含用户走原生控件/浏览器 UI 退出）后清掉标记，
      // 否则下一次 Esc 会被误当作"先退全屏"而白按一次。
      function onFullscreenChange () {
        if (fullscreenEl() || document.webkitIsFullScreen) return
        fullscreenRequested.value = false
      }
      // 全屏中按 Esc：内核把"退全屏"作为 keydown 的默认动作，同一次按键又会冒泡到
      // QDialog 把预览浮层一起关掉（表现为"退全屏即退出预览"）。在 document 捕获阶段
      // 先接管：自己退出全屏 + preventDefault 抑制默认动作 + stopPropagation 阻断对话框，
      // 这样第二次 Esc 才关闭预览。
      function onPreviewEscCapture (event) {
        if (event.key !== 'Escape' || !previewOpen.value) return
        if (!(fullscreenEl() || document.webkitIsFullScreen)) return
        event.preventDefault()
        event.stopPropagation()
        const card = document.querySelector('.files-preview-card')
        exitFullscreen(card ? card.querySelector('video') : null)
        fullscreenRequested.value = false
      }
      function onPreviewEscMessage (event) {
        if (event.data && event.data.type === 'authz-files-esc' && previewOpen.value) {
          previewOpen.value = false
        }
      }

      onBeforeUnmount(() => {
        unsubscribeLocale?.()
        window.clearTimeout(dragTimer)
        window.removeEventListener('keydown', handleKeydown)
        window.removeEventListener('message', onPreviewEscMessage)
        document.removeEventListener('keydown', onPreviewEscCapture, true)
        document.removeEventListener('fullscreenchange', onFullscreenChange)
        document.removeEventListener('webkitfullscreenchange', onFullscreenChange)
        window.removeEventListener('dragover', onWindowDragOver)
        window.removeEventListener('drop', onWindowDrop)
      })

      // 宿主页面通过插槽访问组件状态（如 S3 桶选择器读写 path/previewOpen），
      // 用 defineExpose 显式列出，避免依赖 setup 返回对象。
      defineExpose({
        path, items, loading, previewOpen, previewItem, previewPanelOpen,
        filter, viewMode, sortKey, sortDesc, focusIndex,
        selected, selectionCount, selectedNames, clearSelection, selectAll, toggleSelect,
        load, navigate, open, select, focusFirst, moveFocus,
        kindOf, iconOf, colorOf, fileUrl, sizeText, dateText,
        startRename, startMkdir, askRemove, pickFiles, share, copyPath
      })

      return {
        adapter, broken, colorOf, confirmRemove, confirmRename, copyPath, crumbs,
        startMkdir, detailText, download, dateText, dragging, error, fileInput,
        fileUrl, filter, focused, focusIndex, focusFirst, grid, confirmMkdir,
        iconOf, isTouch, kindOf, loading, load, loadMore, canLoadMore, moreLoading,
        mkdirForm, mkdirOpen, moveFocus, mutating, navigate, onDrop, onItemDouble,
        onItemClick, onPickFiles, onPreviewClick, onPreviewTouchEnd, onPreviewTouchStart,
        open, openInTab, page, pageCount, pageSize, pageSizeOptions, path, pickFiles,
        fullscreenRequested,
        previewCount, previewItem, previewKind, previewOpen, previewPanelOpen,
        previewPosition, previewText, removeForm, removeOpen, renameForm, renameOpen,
        allSelected, askRemoveSelected, askMoveSelected, batchDeleteCopy, clearSelection, confirmMoveSelected, headerSelectState, onHeaderSelect,
        confirmRemoveSelected, downloadSelection, isSelected, moveCopy, movePlaceholderText, moveResolvedText, moveSelectedForm, moveSelectedOpen,
        pruneSelection, rangeSelectTo, removeSelectedForm, removeSelectedOpen, selectedHasDir,
        selectionCount, selectionPathText, selectionText, selectAll, selectedWritableCount, someSelected,
        toggleSelect,
        askRemove, select, share, shown, sizeText, sortBy, sortDesc, sortKey, dirWritable, itemWritable,
        startRename, statText, stepPreview, t, toggleSortOrder, truncated, upload,
        uploading, uploadingText, viewMode, viewOptions, currentLocationText
      }
    }
  }

  // 依赖页面先加载的 Vue 3 完整构建（quasar-umd.js 自带编译器）：
  // template 字符串在这里由 Vue.compile 直接编译。
  window.authzBrowser = { component: browserComponent, kindOf, extOf }
})()
