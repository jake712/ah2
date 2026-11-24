#!/bin/bash

author=233boy
# github=https://github.com/233boy/sing-box

# bash fonts colors
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
_red() { echo -e "${red}$@${none}"; }
_blue() { echo -e "${blue}$@${none}"; }
_cyan() { echo -e "${cyan}$@${none}"; }
_green() { echo -e "${green}$@${none}"; }
_yellow() { echo -e "${yellow}$@${none}"; }
_magenta() { echo -e "${magenta}$@${none}"; }
_red_bg() { echo -e "\e[41m$@${none}"; }

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    echo -e "\n$is_err $@\n" && exit 1
}

warn() {
    echo -e "\n$is_warn $@\n"
}

# root
[[ $EUID != 0 ]] && err "当前非 ${yellow}ROOT用户.${none}"

# alpine apk check
cmd=$(type -P apk)
[[ ! $cmd ]] && err "此脚本仅支持 ${yellow}Alpine Linux${none}."

# openrc or systemd check (allow container fallback if needed)
is_systemd=$(type -P systemctl)
is_openrc=$(type -P rc-service)
if [[ ! $is_systemd && ! $is_openrc ]]; then
    if [[ -f /.dockerenv || -n "${container:-}" ]]; then
        warn "检测到容器环境且无 systemctl/rc-service，将以无服务管理器模式继续..."
        is_container_no_init=1
    else
        err "此系统缺少 ${yellow}(systemctl 或 rc-service)${none}, 请确认 OpenRC 已启用."
    fi
fi

# wget installed or none
is_wget=$(type -P wget)

# arch check
case $(uname -m) in
amd64 | x86_64)
    is_arch=amd64
    ;;
*aarch64* | *armv8*)
    is_arch=arm64
    ;;
*)
    err "此脚本仅支持 64 位系统..."
    ;;
esac

is_core=sing-box
is_core_name=sing-box
is_core_dir=/etc/$is_core
is_core_bin=$is_core_dir/bin/$is_core
is_core_repo=SagerNet/$is_core
is_conf_dir=$is_core_dir/conf
is_log_dir=/var/log/$is_core
is_sh_bin=/usr/local/bin/$is_core
is_sh_dir=$is_core_dir/sh
is_sh_repo=$author/$is_core
# gcompat provides glibc compatibility for prebuilt binaries on musl/Alpine
is_pkg="wget tar bash gcompat jq ca-certificates"
is_config_json=$is_core_dir/config.json
tmp_var_lists=(
    tmpcore
    tmpsh
    tmpjq
    is_core_ok
    is_sh_ok
    is_jq_ok
    is_pkg_ok
)

# tmp dir
tmpdir=$(mktemp -u)
[[ ! $tmpdir ]] && {
    tmpdir=/tmp/tmp-$RANDOM
}

# set up var
for i in ${tmp_var_lists[*]}; do
    export $i=$tmpdir/$i
done

# load bash script
load() {
    . "$is_sh_dir/src/$1"
}

# wget add --no-check-certificate
_wget() {
    [[ $proxy ]] && export https_proxy=$proxy
    wget --no-check-certificate "$@"
}

# print a message
msg() {
    case $1 in
    warn)
        local color=$yellow
        ;;
    err)
        local color=$red
        ;;
    ok)
        local color=$green
        ;;
    *)
        local color=$none
        ;;
    esac

    echo -e "${color}$(date +'%T')${none}) ${2}"
}

# show help msg
show_help() {
    echo -e "Usage: $0 [-f xxx | -l | -p xxx | -v xxx | -h]"
    echo -e "  -f, --core-file <path>          自定义 $is_core_name 文件路径, e.g., -f /root/$is_core-linux-amd64.tar.gz"
    echo -e "  -l, --local-install             本地获取安装脚本, 使用当前目录"
    echo -e "  -p, --proxy <addr>              使用代理下载, e.g., -p http://127.0.0.1:2333"
    echo -e "  -v, --core-version <ver>        自定义 $is_core_name 版本, e.g., -v v1.8.13"
    echo -e "  -h, --help                      显示此帮助界面\n"

    exit 0
}

# install dependent pkg via apk
install_pkg() {
    msg warn "安装 Alpine 依赖包 > $*"
    apk update >/dev/null 2>&1 && apk add --no-cache "$@" >/dev/null 2>&1
    [[ $? == 0 ]] && >"$is_pkg_ok"
}

# download file
download() {
    case $1 in
    core)
        [[ ! $is_core_ver ]] && is_core_ver=$(_wget -qO- "https://api.github.com/repos/${is_core_repo}/releases/latest?v=$RANDOM" | grep tag_name | grep -E -o 'v([0-9.]+)')
        [[ $is_core_ver ]] && link="https://github.com/${is_core_repo}/releases/download/${is_core_ver}/${is_core}-${is_core_ver:1}-linux-${is_arch}.tar.gz"
        name=$is_core_name
        tmpfile=$tmpcore
        is_ok=$is_core_ok
        ;;
    sh)
        link=https://github.com/${is_sh_repo}/releases/latest/download/code.tar.gz
        name="$is_core_name 脚本"
        tmpfile=$tmpsh
        is_ok=$is_sh_ok
        ;;
    jq)
        link=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$is_arch
        name="jq"
        tmpfile=$tmpjq
        is_ok=$is_jq_ok
        ;;
    esac

    [[ $link ]] && {
        msg warn "下载 ${name} > ${link}"
        if _wget -t 3 -q -c "$link" -O "$tmpfile"; then
            mv -f "$tmpfile" "$is_ok"
        fi
    }
}

# get server ip
get_ip() {
    export "$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace | grep ip=)" >/dev/null 2>&1
    [[ -z $ip ]] && export "$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace | grep ip=)" >/dev/null 2>&1
}

# check background tasks status
check_status() {
    if [[ ! -f $is_pkg_ok ]]; then
        msg err "安装依赖包失败"
        msg err "请尝试手动安装依赖包: apk update && apk add --no-cache $is_pkg"
        is_fail=1
    fi

    if [[ $is_wget ]]; then
        [[ ! -f $is_core_ok ]] && {
            msg err "下载 ${is_core_name} 失败"
            is_fail=1
        }
        [[ ! -f $is_sh_ok ]] && {
            msg err "下载 ${is_core_name} 脚本失败"
            is_fail=1
        }
        [[ ! -f $is_jq_ok ]] && {
            msg err "下载 jq 失败"
            is_fail=1
        }
    else
        [[ ! $is_fail ]] && {
            is_wget=1
            [[ ! $is_core_file ]] && download core &
            [[ ! $local_install ]] && download sh &
            [[ $jq_not_found ]] && download jq &
            get_ip
            wait
            check_status
        }
    fi

    [[ $is_fail ]] && {
        exit_and_del_tmpdir
    }
}

# parameters check
pass_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        -f | --core-file)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 /root/$is_core-linux-amd64.tar.gz]"
            } || [[ ! -f $2 ]] && {
                err "($2) 不是一个常规的文件."
            }
            is_core_file=$2
            shift 2
            ;;
        -l | --local-install)
            [[ ! -f ${PWD}/src/core.sh || ! -f ${PWD}/$is_core.sh ]] && {
                err "当前目录 (${PWD}) 非完整的脚本目录."
            }
            local_install=1
            shift 1
            ;;
        -p | --proxy)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 http://127.0.0.1:2333 or -p socks5://127.0.0.1:2333]"
            }
            proxy=$2
            shift 2
            ;;
        -v | --core-version)
            [[ -z $2 ]] && {
                err "($1) 缺少必需参数, 正确使用示例: [$1 v1.8.13]"
            }
            is_core_ver=v${2//v/}
            shift 2
            ;;
        -h | --help)
            show_help
            ;;
        *)
            echo -e "\n${is_err} ($@) 为未知参数...\n"
            show_help
            ;;
        esac
    done
    [[ $is_core_ver && $is_core_file ]] && {
        err "无法同时自定义 ${is_core_name} 版本和 ${is_core_name} 文件."
    }
}

# exit and remove tmpdir
exit_and_del_tmpdir() {
    rm -rf "$tmpdir"
    [[ ! $1 ]] && {
        msg err "哦豁.."
        msg err "安装过程出现错误..."
        echo -e "反馈问题) https://github.com/${is_sh_repo}/issues"
        echo
        exit 1
    }
    exit 0
}

# main
main() {
    [[ -f $is_sh_bin && -d $is_core_dir/bin && -d $is_sh_dir && -d $is_conf_dir ]] && {
        err "检测到脚本已安装, 如需重装请使用${green} ${is_core} reinstall ${none}命令."
    }

    [[ $# -gt 0 ]] && pass_args "$@"

    clear
    echo
    echo "........... $is_core_name script by $author .........."
    echo

    msg warn "开始安装..."
    [[ $is_core_ver ]] && msg warn "${is_core_name} 版本: ${yellow}$is_core_ver${none}"
    [[ $proxy ]] && msg warn "使用代理: ${yellow}$proxy${none}"

    mkdir -p "$tmpdir"

    [[ $is_core_file ]] && {
        cp -f "$is_core_file" "$is_core_ok"
        msg warn "${yellow}${is_core_name} 文件使用 > $is_core_file${none}"
    }

    [[ $local_install ]] && {
        >"$is_sh_ok"
        msg warn "${yellow}本地获取安装脚本 > $PWD ${none}"
    }

    # Alpine OpenRC NTP service check (if installed)
    if [[ $is_openrc && -x /etc/init.d/chronyd ]]; then
        rc-service chronyd start >/dev/null 2>&1 || true
    elif [[ $is_openrc && -x /etc/init.d/ntpd ]]; then
        rc-service ntpd start >/dev/null 2>&1 || true
    fi

    # install dependent pkg via apk
    install_pkg $is_pkg &

    # jq
    if [[ $(type -P jq) ]]; then
        >"$is_jq_ok"
    else
        jq_not_found=1
    fi

    [[ $is_wget ]] && {
        [[ ! $is_core_file ]] && download core &
        [[ ! $local_install ]] && download sh &
        [[ $jq_not_found ]] && download jq &
        get_ip
    }

    wait
    check_status

    if [[ $is_core_file ]]; then
        mkdir -p "$tmpdir/testzip"
        tar zxf "$is_core_ok" --strip-components 1 -C "$tmpdir/testzip" >/dev/null 2>&1
        if [[ $? != 0 || ! -f $tmpdir/testzip/$is_core ]]; then
            msg err "${is_core_name} 文件无法通过测试."
            exit_and_del_tmpdir
        fi
    fi

    [[ ! $ip ]] && {
        msg err "获取服务器 IP 失败."
        exit_and_del_tmpdir
    }

    mkdir -p "$is_sh_dir"

    if [[ $local_install ]]; then
        cp -rf "$PWD"/* "$is_sh_dir"
    else
        tar zxf "$is_sh_ok" -C "$is_sh_dir"
    fi

    mkdir -p "$is_core_dir/bin"
    if [[ $is_core_file ]]; then
        cp -rf "$tmpdir/testzip"/* "$is_core_dir/bin"
    else
        tar zxf "$is_core_ok" --strip-components 1 -C "$is_core_dir/bin"
    fi

    # Alpine default shell is ash; write profile/ashrc in addition to bashrc
    touch /root/.bashrc /root/.ashrc
    echo "alias sb=$is_sh_bin" >>/root/.bashrc
    echo "alias $is_core=$is_sh_bin" >>/root/.bashrc
    echo "alias sb=$is_sh_bin" >>/root/.ashrc
    echo "alias $is_core=$is_sh_bin" >>/root/.ashrc

    sb_cmd_path="${is_sh_bin%/*}/sb"
    ln -sf "$is_sh_dir/$is_core.sh" "$is_sh_bin"
    ln -sf "$is_sh_dir/$is_core.sh" "$sb_cmd_path"

    [[ $jq_not_found ]] && mv -f "$is_jq_ok" /usr/bin/jq

    chmod +x "$is_core_bin" "$is_sh_bin" /usr/bin/jq "$sb_cmd_path"

    mkdir -p "$is_log_dir"

    msg ok "生成配置文件..."

    load systemd.sh
    is_new_install=1
    install_service "$is_core" >/dev/null 2>&1

    mkdir -p "$is_conf_dir"

    load core.sh
    add hy2
    wait
    exit_and_del_tmpdir ok
}

main "$@"
