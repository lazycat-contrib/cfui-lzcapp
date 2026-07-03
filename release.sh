#!/usr/bin/env bash
set -euo pipefail

# 一键发布脚本：复制上游镜像 -> 更新版本 -> 构建 LPK -> 发布应用商店 -> git 提交推送
#
# 用法:
#   ./release.sh 0.9.4                      # 完整流程（发布 + 推送）
#   ./release.sh 0.9.4 --no-publish         # 只更新构建，不发布商店
#   ./release.sh 0.9.4 --no-push            # 发布但不推送 git
#   ./release.sh 0.9.4 --changelog '修复 xxx'
#
# 上游镜像从 lzc-manifest.yml 中 image: 行上方的注释推导（如 # czyt/cfui:v0.9.3），
# tag 的 v 前缀会自动保留。

usage() {
  sed -n '5,14p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*" >&2; }

PACKAGE_FILE=package.yml
MANIFEST_FILE=lzc-manifest.yml
BUILD_FILE=lzc-build.yml

VERSION=${1:-}
[[ -n "$VERSION" && "$VERSION" != "-h" && "$VERSION" != "--help" ]] || { usage; exit 1; }
shift
VERSION=${VERSION#v}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "版本号格式不正确: $VERSION"

PUBLISH=1
PUSH=1
CHANGELOG=""
LANG_CODE=zh

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-publish) PUBLISH=0; shift ;;
    --no-push) PUSH=0; shift ;;
    --changelog) CHANGELOG=${2:-}; shift 2 ;;
    --lang) LANG_CODE=${2:-zh}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

command -v git >/dev/null || die "缺少 git"
[[ -f "$PACKAGE_FILE" && -f "$MANIFEST_FILE" && -f "$BUILD_FILE" ]] || die "请在项目根目录运行"

# 已跟踪文件必须干净，避免把无关改动一起提交（未跟踪文件不受影响）
if [[ "$PUSH" == "1" ]] && [[ -n "$(git status --porcelain -uno)" ]]; then
  die "git 工作区有未提交的改动，请先提交或暂存（或加 --no-push）"
fi

CURRENT_VERSION=$(awk -F':[[:space:]]*' '/^version:/ { print $2; exit }' "$PACKAGE_FILE")
[[ "$VERSION" != "$CURRENT_VERSION" ]] || die "版本 $VERSION 与当前版本相同"

# 从 image: 行上方注释推导上游镜像（保留 v 前缀）
COMMENT_IMAGE=$(awk '
  /^[[:space:]]*#[[:space:]]*[A-Za-z0-9][A-Za-z0-9._\/-]*:[A-Za-z0-9]/ {
    c = $0; sub(/^[[:space:]]*#[[:space:]]*/, "", c); sub(/[[:space:]]*$/, "", c); comment = c; next
  }
  /^[[:space:]]*image:/ { if (comment != "") { print comment; exit } }
  { comment = "" }
' "$MANIFEST_FILE")
[[ -n "$COMMENT_IMAGE" ]] || die "未在 $MANIFEST_FILE 的 image: 行上方找到上游镜像注释"

IMAGE_REPO=${COMMENT_IMAGE%:*}
OLD_TAG=${COMMENT_IMAGE##*:}
if [[ "$OLD_TAG" == v* ]]; then
  SOURCE_IMAGE="${IMAGE_REPO}:v${VERSION}"
else
  SOURCE_IMAGE="${IMAGE_REPO}:${VERSION}"
fi

note "当前版本: $CURRENT_VERSION -> 新版本: $VERSION"
note "上游镜像: $SOURCE_IMAGE"

# 复制镜像到懒猫 registry
if command -v fish >/dev/null 2>&1 && fish -lc 'functions -q lzc-copy-image' >/dev/null 2>&1; then
  note "复制镜像 (fish lzc-copy-image)..."
  COPY_OUTPUT=$(COPY_IMAGE="$SOURCE_IMAGE" fish -lc 'lzc-copy-image "$COPY_IMAGE"' 2>&1) || {
    printf '%s\n' "$COPY_OUTPUT" >&2; die "镜像复制失败"; }
else
  command -v lzc-cli >/dev/null || die "缺少 lzc-cli"
  note "复制镜像 (lzc-cli appstore copy-image)..."
  COPY_OUTPUT=$(lzc-cli appstore copy-image "$SOURCE_IMAGE" 2>&1) || {
    printf '%s\n' "$COPY_OUTPUT" >&2; die "镜像复制失败"; }
fi
printf '%s\n' "$COPY_OUTPUT" >&2

LAZYCAT_IMAGE=$(printf '%s\n' "$COPY_OUTPUT" | grep -Eo 'registry\.lazycat\.cloud/[A-Za-z0-9._:@/-]+' | tail -n 1)
[[ -n "$LAZYCAT_IMAGE" ]] || die "未能从 copy-image 输出解析 registry.lazycat.cloud 镜像地址，已停止（文件未修改）"
note "懒猫镜像: $LAZYCAT_IMAGE"

# 更新 package.yml 版本
sed -i "0,/^version:/s|^version:.*|version: ${VERSION}|" "$PACKAGE_FILE"

# 更新 manifest：上游镜像注释 + image 行
ESCAPED_COMMENT=$(printf '%s' "$COMMENT_IMAGE" | sed 's/[.[\*^$/]/\\&/g')
sed -i "s|^\([[:space:]]*\)# ${ESCAPED_COMMENT}[[:space:]]*$|\1# ${SOURCE_IMAGE}|" "$MANIFEST_FILE"
sed -i "s|^\([[:space:]]*\)image:[[:space:]]*registry\.lazycat\.cloud/.*|\1image: ${LAZYCAT_IMAGE}|" "$MANIFEST_FILE"

grep -q "# ${SOURCE_IMAGE}" "$MANIFEST_FILE" || die "manifest 注释更新失败，请检查 $MANIFEST_FILE"
grep -q "image: ${LAZYCAT_IMAGE}" "$MANIFEST_FILE" || die "manifest image 更新失败，请检查 $MANIFEST_FILE"

# 构建 LPK
PACKAGE_ID=$(awk -F':[[:space:]]*' '/^package:/ { print $2; exit }' "$PACKAGE_FILE")
LPK_FILE="${PACKAGE_ID}-v${VERSION}.lpk"

command -v lzc-cli >/dev/null || die "缺少 lzc-cli"
note "构建 LPK..."
lzc-cli project build -f "$BUILD_FILE"
[[ -f "$LPK_FILE" ]] || die "构建产物不存在: $LPK_FILE"
note "构建完成: $LPK_FILE"

# 发布到应用商店
if [[ "$PUBLISH" == "1" ]]; then
  CHANGELOG=${CHANGELOG:-"更新到 ${VERSION}"}
  if command -v fish >/dev/null 2>&1 && fish -lc 'functions -q lzc-publish' >/dev/null 2>&1; then
    note "发布 (fish lzc-publish): $LPK_FILE \"$CHANGELOG\" $LANG_CODE"
    LPK_FILE="$LPK_FILE" CHANGELOG="$CHANGELOG" LANG_CODE="$LANG_CODE" \
      fish -lc 'lzc-publish "$LPK_FILE" "$CHANGELOG" "$LANG_CODE"'
  else
    note "发布 (lzc-cli appstore publish)..."
    lzc-cli appstore publish "$LPK_FILE" -c "$CHANGELOG" --clang "$LANG_CODE"
  fi
  note "已提交应用商店审核"
else
  note "跳过应用商店发布 (--no-publish)"
fi

# git 提交并推送
if [[ "$PUSH" == "1" ]]; then
  git add "$PACKAGE_FILE" "$MANIFEST_FILE" "$LPK_FILE"
  git commit -m "bump ${VERSION}"
  note "推送到远端..."
  git push origin HEAD
  note "git 推送完成"
else
  note "跳过 git 提交推送 (--no-push)"
fi

echo ""
echo "发布完成:"
echo "  版本:     $CURRENT_VERSION -> $VERSION"
echo "  上游镜像: $SOURCE_IMAGE"
echo "  懒猫镜像: $LAZYCAT_IMAGE"
echo "  LPK:      $LPK_FILE"
echo "  商店发布: $([[ $PUBLISH == 1 ]] && echo 是 || echo 否)"
echo "  git 推送: $([[ $PUSH == 1 ]] && echo 是 || echo 否)"
