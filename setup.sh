#!/bin/bash
set -e

# ============================================
# Geek Blog 快速设置脚本
# ============================================

echo ""
echo "🎉 极客博客快速设置脚本"
echo ""

if ! command -v hugo &> /dev/null; then
    echo "❌ Hugo 未安装，请先安装 Hugo Extended 版本"
    echo ""
    echo "📦 安装方式："
    echo "  macOS:    brew install hugo"
    echo "  Ubuntu:   sudo apt install hugo"
    echo "  或其他:   https://github.com/gohugoio/hugo/releases"
    echo ""
    exit 1
fi

echo "✅ Hugo 已安装: $(hugo version | head -1)"

# 检查是否是 extended 版本
if ! hugo version | grep -q extended; then
    echo "⚠️  警告：建议安装 Hugo Extended 版本以支持 SCSS"
fi

echo ""
echo "📝 请输入你的 GitHub 用户名（用于仓库和 Pages）:"
read -r GITHUB_USER

if [ -z "$GITHUB_USER" ]; then
    echo "❌ 用户名不能为空"
    exit 1
fi

echo "📝 请输入你的邮箱:"
read -r EMAIL

echo "📝 请输入博客标题 [Geek Blog]:"
read -r BLOG_TITLE
BLOG_TITLE=${BLOG_TITLE:-Geek Blog}

# 更新配置文件
echo "🔧 正在更新配置文件..."
sed -i.bak "s|yusanwen-code|$GITHUB_USER|g" hugo.yml || true
sed -i.bak "s|your@email.com|$EMAIL|g" hugo.yml || true
sed -i.bak "s|title: Geek Blog|title: $BLOG_TITLE|g" hugo.yml || true
rm -f hugo.yml.bak
echo "✅ 配置文件已更新"

# 更新 README 中的用户名
sed -i.bak "s|yusanwen-code|$GITHUB_USER|g" README.md || true
rm -f README.md.bak

echo ""
echo "🚀 设置完成！"
echo ""
echo "接下来："
echo "  1. cd my-geek-blog"
echo "  2. hugo server -D    # 本地预览"
echo "  3. git init"
echo "     git add ."
echo "     git commit -m 'initial'"
echo "     git remote add origin https://github.com/$GITHUB_USER/$GITHUB_USER.github.io.git"
echo "     git push -u origin main"
echo "  4. 在 GitHub 仓库 Settings → Pages 中启用 gh-pages 分支"
echo "  5. 访问 https://$GITHUB_USER.github.io 查看博客 🎉"
echo ""
