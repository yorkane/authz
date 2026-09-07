# 测试辅助：准备可挂载的 lualib 目录。
#
# 测试用只读挂载覆盖镜像内的 /usr/local/openresty/site/lualib，会连带遮蔽镜像里
# 构建的 lfs.so（文件浏览模块依赖），导致控制面 500。这里把仓库 lualib 复制到临时
# 目录，并从镜像里取出 lfs.so 补齐，返回应当挂载的目录路径。
prepare_lualib_mount() {
    local image=$1
    local work_dir=$2
    local target="$work_dir/lualib"
    mkdir -p "$target"
    cp -a "$REPO_DIR/lualib/." "$target/"
    if [[ ! -e "$target/lfs.so" ]]; then
        if docker run --rm --entrypoint sh "$image" -c \
            'cat /usr/local/openresty/site/lualib/lfs.so' > "$target/lfs.so" 2>/dev/null \
            && [[ -s "$target/lfs.so" ]]; then
            :
        else
            rm -f "$target/lfs.so"
        fi
    fi
    printf '%s\n' "$target"
}
