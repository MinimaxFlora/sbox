# shellcheck shell=bash
# ui.sh — 终端界面元素：横幅、分隔线、表格、键值行、菜单

if [[ -n ${SBOX_UI_SH:-} ]]; then return 0; fi
readonly SBOX_UI_SH=1

readonly UI_WIDTH=${UI_WIDTH:-64}

# 首屏横幅
ui_banner() {
    local ver=${1:-$(sbox_script_version)}
    printf '\n'
    printf '%s   ███████╗ ██████╗  ██████╗ ██╗  ██╗%s\n' "$C_CYAN" "$C_RESET"
    printf '%s   ██╔════╝ ██╔══██╗██╔═══██╗╚██╗██╔╝%s\n' "$C_CYAN" "$C_RESET"
    printf '%s   ███████╗ ██████╔╝██║   ██║ ╚███╔╝ %s\n' "$C_CYAN" "$C_RESET"
    printf '%s   ╚════██║ ██╔══██╗██║   ██║ ██╔██╗ %s\n' "$C_CYAN" "$C_RESET"
    printf '%s   ███████║██████╔╝╚██████╔╝██╔╝ ██╗%s\n' "$C_CYAN" "$C_RESET"
    printf '%s   ╚══════╝╚═════╝  ╚═════╝ ╚═╝  ╚═╝%s\n' "$C_CYAN" "$C_RESET"
    printf '   %sSing-Box 一键脚本 · v%s%s\n' "$C_DIM" "$ver" "$C_RESET"
    printf '\n'
}

ui_hr() {
    local w=${1:-$UI_WIDTH} line
    printf -v line '%*s' "$w" ''
    printf '%s%s%s\n' "$C_GREY" "${line// /─}" "$C_RESET"
}

ui_title() { printf '\n  %s▎%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

ui_sub() { printf '  %s%s%s\n' "$C_GREY" "$*" "$C_RESET"; }

ui_note() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

ui_kv() { # ui_kv <键> <值> [键宽度]
    local k=$1 v=${2:-} kw=${3:-8}
    printf '  %s%s%s %s\n' "$C_GREY" "$(pad_c "$k" "$kw")" "$C_RESET" "$v"
}

# ui_table <列宽列表(空格分隔)> <表头(制表符分隔)> <行...>
# 最后一列不补空格；值内含制表符分隔字段。
ui_table() {
    local widths=$1 header=$2
    shift 2
    local -a w=()
    local IFS=' '
    read -r -a w <<<"$widths"

    _ui_row() {
        local line=$1 i field
        local -a fields=()
        local IFS=$'\t'
        read -r -a fields <<<"$line"
        for ((i = 0; i < ${#fields[@]}; i++)); do
            field=${fields[i]}
            if ((i < ${#w[@]})); then
                printf '%s  ' "$(pad_c "$field" "${w[i]}")"
            else
                printf '%s' "$field"
            fi
        done
        printf '\n'
    }

    printf '%s' "$C_GREY"
    printf '  '
    _ui_row "$header"
    printf '%s' "$C_RESET"
    local i line
    for i in "${w[@]}"; do
        printf -v line '%*s' "$i" ''
        printf '  %s%s%s  ' "$C_GREY" "${line// /─}" "$C_RESET"
    done
    printf '\n'
    for line in "$@"; do
        [[ -n $line ]] || continue
        printf '  '
        _ui_row "$line"
    done
}

# 状态点
ui_state() {
    case ${1:-} in
        running | active | ok) printf '%s●%s %s' "$C_GREEN" "$C_RESET" "${2:-运行中}" ;;
        stopped | inactive | dead) printf '%s●%s %s' "$C_RED" "$C_RESET" "${2:-已停止}" ;;
        warn) printf '%s●%s %s' "$C_YELLOW" "$C_RESET" "${2:-警告}" ;;
        *) printf '%s●%s %s' "$C_GREY" "$C_RESET" "${2:-未知}" ;;
    esac
}

ui_badge() { # ui_badge <文本> <颜色>
    printf '%s%s%s' "${2:-$C_CYAN}" "$1" "$C_RESET"
}

# ui_menu <标题> <项数> — 由调用者接续输出条目
ui_menu_head() { printf '\n'; ui_title "$1"; printf '\n'; }

ui_menu_item() { # ui_menu_item <编号> <描述> [快捷键hint]
    printf '  %s%2s%s) %s %s\n' "$C_CYAN" "$1" "$C_RESET" "$2" "${3:+${C_GREY}[$3]${C_RESET}}"
}

# 读取菜单输入到全局 UI_CHOICE
ui_prompt() { # ui_prompt <提示>
    printf '\n  %s%s%s ' "$C_BOLD" "${1:-请选择}" "$C_RESET"
    UI_CHOICE=''
    read -r UI_CHOICE || UI_CHOICE=''
}

# 漂亮的确认框（用于展示安装完成后的摘要）
ui_panel() { # ui_panel <标题> <正文(多行)>
    local title=$1 body=$2 line
    body=${body%$'\n'}
    printf '\n  %s╭─ %s %s\n' "$C_BLUE" "$title" "$C_RESET"
    while IFS= read -r line; do
        printf '  %s│%s %s\n' "$C_BLUE" "$C_RESET" "$line"
    done <<<"$body"
    printf '  %s╰%s\n' "$C_BLUE" "$C_RESET"
}

ui_block() { # ui_block <颜色> <行...>
    local color=$1 line
    shift
    for line in "$@"; do printf '%s%s%s\n' "$color" "$line" "$C_RESET"; done
}
