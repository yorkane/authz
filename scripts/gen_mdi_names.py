# 从 admin/vendor/quasar-umd.css 提取打包 MDI v7 字体的全部图标名，生成 admin/vendor/mdi-names.js。
# 前端图标选择器据此提供全量可搜索图标；升级 vendor 后重跑本脚本即可。
import re, io, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
css = io.open(os.path.join(root, 'admin/vendor/quasar-umd.css'), encoding='utf-8', errors='ignore').read()
names = sorted(set(n for n in re.findall(r'mdi-[a-z0-9]+(?:-[a-z0-9]+)*', css) if len(n) > 4))
header = '// 打包 MDI v7 字体中全部可用图标名（scripts/gen_mdi_names.py 生成，请勿手改）。' + chr(10) + 'window.mdiNames = '
body = '[' + ','.join("'" + n + "'" for n in names) + ']' + chr(10)
io.open(os.path.join(root, 'admin/vendor/mdi-names.js'), 'w', encoding='utf-8').write(header + body)
print('names:', len(names))
