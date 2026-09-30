#!/usr/bin/env bash
# =============================================================================
#  from123_testdata.sh —— 生成用于自检的「仿真云盘」目录树
#  不是迁移脚本的一部分，只在你想重跑自检时用得上。
#  刻意塞进了各种会让你半夜翻车的名字：中文、空格、引号、& # $ % ;、emoji、
#  全角括号、以 - 开头、末尾带空格、超长名、15 层嵌套、单目录 3000 文件、
#  空目录、以及一个 200MB 大文件（用于测中断续传）。
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
ROOT="${1:-$ROOT_DIR/.selftest/cloud/我的文件}"
TREE_TXT="$ROOT_DIR/.selftest/tree.txt"

if [[ -d "$ROOT" ]]; then
  echo "仿真树已存在: $ROOT（要重建先 rm -rf）"
  find "$ROOT" -type f | wc -l | xargs echo "文件数:"
  exit 0
fi

echo "生成仿真树: $ROOT"
mkdir -p "$ROOT"; cd "$ROOT"

# 1) 照片：单目录 300 文件 + 中文名 + 空相册
mkdir -p "照片/LanZhou-oldPC/20250731/0"
for i in $(seq 1 300); do printf 'jpg-%s' "$i" > "照片/LanZhou-oldPC/20250731/0/${i}.jpg"; done
printf x > "照片/LanZhou-oldPC/20250731/0/21个月の堂.jpg"
printf x > "照片/LanZhou-oldPC/20250731/0/IMG_6684.JPG"
mkdir -p "照片/上海-原图分享" "照片/empty_album"

# 2) 特殊字符矩阵
mkdir -p "临时中转"; cd "临时中转"
for n in "空格 名字.txt" "单引号'.txt" '双引号".txt' 'amp&.txt' 'hash#.txt' \
         '括号（全角）.txt' 'emoji🎉.txt' '-dash开头.txt' '百分%号.txt' \
         '反斜杠\.txt' '美元$符.txt' '分号;冒号:.txt' "末尾空格 .txt" \
         '星号*.txt' '问号?.txt' '竖线|.txt' '大于小于<>.txt'; do
  printf 'hello' > "$n"
done
printf 'long' > "$(python3 -c "print('长'*70+'.txt')")"
mkdir -p "空目录里面也有/更深一层"; cd "$ROOT"

# 3) 15 层嵌套（模仿 Windows 备份结构）
D="旧电脑备份/c/Users/Default/AppData/Local/Microsoft/Windows/INetCache/IE/AAAAAAAA/BBBBBBBB/CCCCCCCC/DDDDDDDD"
mkdir -p "$D"
printf 'NTUSER' > "$D/NTUSER.DAT"
printf 'reg' > "$D/NTUSER.DAT{53b39e88-18c4-11ea-a811-000d3aa4692b}.TM.blf"

# 4) 单目录 3000 文件（模仿 flac 音乐目录，测大目录）
mkdir -p "番剧合集！/歌曲"; cd "番剧合集！/歌曲"
for i in $(seq 1 3000); do printf 'f' > "曲目 $i - 日本群星、ryo.flac"; done
cd "$ROOT"

# 5) 200MB 大文件（中断续传测试用）+ 若干 1MB
mkdir -p "代码备份"
head -c 200000000 /dev/urandom > "代码备份/大文件-200MB.bin"
mkdir -p "写作备份"
for i in 1 2 3 4 5; do head -c 1048576 /dev/urandom > "写作备份/备份$i.zip"; done

# 6) 根目录散装文件
printf 'apk' > "Phigros_3.17.0.1.apk"
printf 'zip' > "归档备份.zip"
printf 'html' > "favorites_2025_6_2.html"
head -c 2097152 /dev/urandom > "系统.7z"
printf 'doc' > "七下U9.docx"
printf 'mov' > "IMG_8765.MOV"

# 7) 生成一份「目录树 txt」，供 crosscheck 用例使用（故意留 2 个幽灵条目）
mkdir -p "$ROOT_DIR/.selftest"
{
  echo "我的文件"
  while IFS= read -r f; do printf '│  %s\n' "$(basename "$f")"; done < <(find "$ROOT" -type f | sort)
  echo "│  幽灵文件-只存在于目录树里.txt"
  echo "│  幽灵文件-2.txt"
} > "$TREE_TXT"
echo "目录树 txt: $TREE_TXT"

echo "=== 完成 ==="
find "$ROOT" -type f | wc -l | xargs echo "文件数:"
find "$ROOT" -type d | wc -l | xargs echo "目录数:"
du -sh "$ROOT" | cut -f1 | xargs echo "总大小:"
