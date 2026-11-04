#!/bin/bash

# Interactive editor for global outbounds and inbound route rules.

ob_config=$is_config_json

ob_error() {
    msg "\n${is_err} $*\n"
}

ob_read() {
    local prompt=$1 value
    while :; do
        echo -ne "$prompt"
        IFS= read -r value || return 1
        if [[ $value ]]; then
            ob_value=$value
            return 0
        fi
        msg "此项不能为空。"
    done
}

ob_read_port() {
    local prompt=$1 value
    while :; do
        ob_read "$prompt" || return 1
        value=$ob_value
        if [[ $value =~ ^[0-9]+$ ]] && ((value > 0 && value <= 65535)); then
            ob_value=$value
            return 0
        fi
        msg "请输入 1 到 65535 之间的端口。"
    done
}

ob_config_ready() {
    if [[ ! -f $ob_config ]]; then
        ob_error "找不到全局配置文件: $ob_config"
        return 1
    fi
    if ! jq -e '(.outbounds | type) == "array" and ((.route // {}) | type) == "object" and ((.route.rules // []) | type) == "array"' "$ob_config" >/dev/null 2>&1; then
        ob_error "outbounds 或 route 配置结构无效，请先运行 sing-box fix-config.json。"
        return 1
    fi
    return 0
}

ob_list_outbounds() {
    jq -r '.outbounds | to_entries[] | "\(.key + 1)) \(.value.tag // "(无名称)") [\(.value.type // "未知类型")]"' "$ob_config"
}

ob_inbound_tags() {
    local file
    for file in "$is_conf_dir"/*.json; do
        [[ -f $file ]] || continue
        jq -r '.inbounds[]?.tag // empty' "$file" 2>/dev/null
    done | awk 'NF && !seen[$0]++'
}

ob_select_index() {
    local count=$1 prompt=$2 answer
    ob_index=
    while :; do
        echo -ne "$prompt [1-$count, 0 返回]: "
        IFS= read -r answer || return 1
        [[ $answer == 0 ]] && return 1
        if [[ $answer =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= count)); then
            ob_index=$((answer - 1))
            return 0
        fi
        msg "请输入有效序号。"
    done
}

ob_pick_outbound() {
    local count
    count=$(jq '.outbounds | length' "$ob_config")
    ((count > 0)) || {
        ob_error "当前没有出站配置。"
        return 1
    }
    ob_list_outbounds
    ob_select_index "$count" "请选择出站" || return 1
    ob_selected=$(jq ".outbounds[$ob_index]" "$ob_config")
    ob_selected_tag=$(jq -r '.tag // empty' <<<"$ob_selected")
}

ob_pick_inbounds() {
    local answer value invalid i
    local -a tags=() selected=()
    mapfile -t tags < <(ob_inbound_tags)
    if [[ ${#tags[@]} -eq 0 ]]; then
        ob_error "当前没有可用入站配置。"
        return 1
    fi
    msg "当前入站："
    for ((i = 0; i < ${#tags[@]}; i++)); do
        msg "$((i + 1))) ${tags[$i]}"
    done
    while :; do
        echo -ne "选择入站序号（可用空格分隔多个序号，0 返回）: "
        IFS= read -r answer || return 1
        [[ $answer == 0 ]] && return 1
        selected=()
        invalid=
        for value in $answer; do
            if [[ ! $value =~ ^[0-9]+$ ]] || ((value < 1 || value > ${#tags[@]})); then
                invalid=1
                break
            fi
            selected+=("${tags[$((value - 1))]}")
        done
        if [[ ! $invalid && ${#selected[@]} -gt 0 ]]; then
            ob_selected_inbounds=$(printf '%s\n' "${selected[@]}" | awk '!seen[$0]++' | jq -R . | jq -s .)
            return 0
        fi
        msg "请输入有效的入站序号。"
    done
}

ob_pick_rule() {
    local count
    count=$(jq '(.route.rules // []) | length' "$ob_config")
    if ((count == 0)); then
        ob_error "当前没有路由规则。"
        return 1
    fi
    jq -r '(.route.rules // []) | to_entries[] | "\(.key + 1)) \(.value | tojson)"' "$ob_config"
    ob_select_index "$count" "请选择规则" || return 1
    ob_selected_rule=$(jq ".route.rules[$ob_index]" "$ob_config")
}

ob_show_json() {
    ob_json=$1
    msg "\n配置预览："
    jq . <<<"$ob_json"
}

ob_build_sniff_rule() {
    local scope
    msg "Sniff 规则范围："
    msg "1) 指定入站"
    msg "2) 全局"
    echo -ne "请选择 [1-2]: "
    IFS= read -r scope || return 1
    case $scope in
    1)
        ob_pick_inbounds || return 1
        ob_json=$(jq -n --argjson inbound "$ob_selected_inbounds" '{inbound:$inbound,action:"sniff",sniffer:["http","tls","quic"]}')
        ;;
    2) ob_json=$(jq -n '{action:"sniff",sniffer:["http","tls","quic"]}') ;;
    *) msg "已取消。"; return 1 ;;
    esac
}

ob_save() {
    local filter=$1 tmp backup mode
    shift
    filter="$filter | if (.route.rules | type) == \"array\" then .route.rules |= (map(if has(\"outbound\") and (has(\"action\") | not) then . + {action:\"route\"} else . end) as \$rules | [\$rules[] | select(.action == \"sniff\")] + [\$rules[] | select(.action != \"sniff\")]) else . end"
    tmp=$(mktemp "${ob_config}.tmp.XXXXXX") || {
        ob_error "无法创建临时配置文件。"
        return 1
    }
    if ! jq "$@" "$filter" "$ob_config" >"$tmp"; then
        rm -f "$tmp"
        ob_error "更新配置失败，原配置未修改。"
        return 1
    fi
    if ! "$is_core_bin" check -c "$tmp"; then
        rm -f "$tmp"
        ob_error "sing-box 配置校验失败，原配置未修改。"
        return 1
    fi
    mode=$(stat -c '%a' "$ob_config" 2>/dev/null)
    [[ $mode ]] && chmod "$mode" "$tmp"
    backup=$(mktemp "${ob_config}.bak.XXXXXX") || {
        rm -f "$tmp"
        ob_error "无法创建备份文件，原配置未修改。"
        return 1
    }
    if ! cp -p "$ob_config" "$backup" || ! mv -f "$tmp" "$ob_config"; then
        rm -f "$tmp"
        ob_error "备份或写入配置失败。${backup:+备份文件: $backup}"
        return 1
    fi
    msg "\n配置已保存，备份文件: $backup"
    manage restart &
}

ob_read_outbound() {
    local current=$1 type name server port username password remove_auth
    if [[ $current ]]; then
        name=$(jq -r '.tag // empty' <<<"$current")
        type=$(jq -r '.type // empty' <<<"$current")
        server=$(jq -r '.server // empty' <<<"$current")
        port=$(jq -r '.server_port // empty' <<<"$current")
        username=$(jq -r '.username // empty' <<<"$current")
        password=$(jq -r '.password // empty' <<<"$current")
    fi

    msg "\n1. 出站名称 (tag)"
    if [[ $current ]]; then
        echo -ne "请输入出站名称 [$name]: "
        IFS= read -r answer || return 1
        [[ $answer ]] && name=$answer
    else
        ob_read "请输入出站名称: " || return 1
        name=$ob_value
    fi

    msg "\n2. 选择出站类型"
    msg "1) HTTP"
    msg "2) SOCKS"
    [[ $type == http ]] && msg "当前类型: HTTP"
    [[ $type == socks ]] && msg "当前类型: SOCKS"
    while :; do
        echo -ne "请选择 [1-2, 回车保留当前类型]: "
        IFS= read -r answer || return 1
        case $answer in
        1) type=http; break ;;
        2) type=socks; break ;;
        '') [[ $type ]] && break ;;
        *) msg "请输入 1 或 2。" ;;
        esac
    done

    msg "\n3. 配置 ${type^^} 连接"
    if [[ $current ]]; then
        echo -ne "服务器地址 [$server]: "
        IFS= read -r answer || return 1
        [[ $answer ]] && server=$answer
    else
        ob_read "服务器地址: " || return 1
        server=$ob_value
    fi
    if [[ $current ]]; then
        echo -ne "服务器端口 [$port]: "
        IFS= read -r answer || return 1
        [[ $answer ]] && port=$answer
        if [[ ! $port =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
            ob_error "请输入 1 到 65535 之间的端口。"
            return 1
        fi
    else
        ob_read_port "服务器端口: " || return 1
        port=$ob_value
    fi

    if [[ $current ]]; then
        [[ $username ]] && msg "当前用户名: $username"
        echo -ne "用户名 (回车保留当前认证，输入 - 删除认证): "
        IFS= read -r answer || return 1
        if [[ $answer == - ]]; then
            username=
            password=
            remove_auth=1
        elif [[ $answer ]]; then
            username=$answer
            echo -ne "密码 [回车保留当前密码]: "
            IFS= read -r answer || return 1
            [[ $answer ]] && password=$answer
        fi
    else
        echo -ne "用户名 (无认证留空): "
        IFS= read -r username
        if [[ $username ]]; then
            echo -ne "密码: "
            IFS= read -r password
        fi
    fi

    if [[ $username ]]; then
        ob_json=$(jq -n --arg tag "$name" --arg type "$type" --arg server "$server" --argjson port "$port" --arg username "$username" --arg password "$password" \
            '{tag:$tag,type:$type,server:$server,server_port:$port,username:$username,password:$password}')
    else
        ob_json=$(jq -n --arg tag "$name" --arg type "$type" --arg server "$server" --argjson port "$port" \
            '{tag:$tag,type:$type,server:$server,server_port:$port}')
    fi
    if [[ $current ]]; then
        ob_json=$(jq -n --argjson old "$current" --argjson generated "$ob_json" --arg remove_auth "$remove_auth" \
            'if $old.type != $generated.type then ($old * $generated | if $generated.type == "http" then del(.network, .udp_over_tcp, .version) else del(.path, .headers, .version, .disable_version_fallback, .tls, .idle_timeout, .keep_alive_period, .stream_receive_window, .connection_receive_window, .max_concurrent_streams, .initial_packet_size, .disable_path_mtu_discovery) | .version = "5" end) else $old * $generated end | if $remove_auth == "1" then del(.username, .password) else . end')
    fi
    jq -e '(.tag | type == "string" and length > 0) and (.type == "http" or .type == "socks") and (.server | type == "string" and length > 0) and (.server_port | type == "number" and . > 0 and . <= 65535)' <<<"$ob_json" >/dev/null || {
        ob_error "出站 JSON 缺少有效 tag、类型、服务器地址或端口。"
        return 1
    }
    if jq -e 'has("username") != has("password")' <<<"$ob_json" >/dev/null; then
        ob_error "认证必须同时提供 username 和 password。"
        return 1
    fi
    ob_show_json "$ob_json"
}

ob_url_decode() {
    local value=$1 encoded hex char
    while [[ $value =~ %([[:xdigit:]]{2}) ]]; do
        encoded=${BASH_REMATCH[0]}
        hex=${BASH_REMATCH[1]}
        printf -v char '%b' "\\x$hex"
        value=${value/"$encoded"/"$char"}
    done
    ob_decoded=$value
}

ob_parse_link_host_port() {
    local authority=$1
    if [[ $authority =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        ob_server=${BASH_REMATCH[1]}
        ob_port=${BASH_REMATCH[2]}
    elif [[ $authority =~ ^([^:]+):([0-9]+)$ ]]; then
        ob_server=${BASH_REMATCH[1]}
        ob_port=${BASH_REMATCH[2]}
    else
        ob_error "链接中的服务器地址或端口格式无效。"
        return 1
    fi
    while [[ ${#ob_port} -gt 1 && $ob_port == 0* ]]; do ob_port=${ob_port#0}; done
    if [[ ${#ob_port} -gt 5 ]]; then
        ob_error "链接端口必须在 1 到 65535 之间。"
        return 1
    fi
    if ((ob_port < 1 || ob_port > 65535)); then
        ob_error "链接端口必须在 1 到 65535 之间。"
        return 1
    fi
}

ob_parse_outbound_link() {
    local url=$1 scheme remainder fragment query authority userinfo host_port decoded method password
    local alpn insecure pin obfs obfs_password sni key value pair tag
    local tls alpn_json pin_hex pin_base64 pin_byte ob_server ob_port i

    url=${url#"${url%%[![:space:]]*}"}
    url=${url%"${url##*[![:space:]]}"}
    if [[ ! $url =~ ^([[:alpha:]][[:alnum:]+.-]*):// ]]; then
        ob_error "请输入 Shadowsocks 或 Hysteria2 链接。"
        return 1
    fi
    scheme=${BASH_REMATCH[1],,}
    remainder=${url#*://}
    fragment=
    if [[ $remainder == *#* ]]; then
        fragment=${remainder#*#}
        remainder=${remainder%%#*}
        ob_url_decode "$fragment"
        fragment=$ob_decoded
    fi
    query=
    if [[ $remainder == *\?* ]]; then
        query=${remainder#*\?}
        remainder=${remainder%%\?*}
    fi
    authority=$remainder

    case $scheme in
    ss)
        if [[ $authority != *@* ]]; then
            ob_error "Shadowsocks 链接缺少 Base64 凭据与服务器地址分隔符 @。"
            return 1
        fi
        userinfo=${authority%%@*}
        host_port=${authority#*@}
        userinfo=${userinfo//-/+}
        userinfo=${userinfo//_/\/}
        while (( ${#userinfo} % 4 )); do userinfo+='='; done
        if ! decoded=$(printf '%s' "$userinfo" | base64 --decode 2>/dev/null); then
            ob_error "Shadowsocks 链接中的 Base64 凭据无效。"
            return 1
        fi
        if [[ $decoded != *:* ]]; then
            ob_error "Shadowsocks 凭据必须包含加密方法和密码。"
            return 1
        fi
        method=${decoded%%:*}
        password=${decoded#*:}
        [[ $method && $password ]] || {
            ob_error "Shadowsocks 加密方法和密码不能为空。"
            return 1
        }
        ob_parse_link_host_port "$host_port" || return 1
        tag=${fragment:-"ss-$ob_server-$ob_port"}
        ob_json=$(jq -n --arg tag "$tag" --arg server "$ob_server" --argjson port "$ob_port" --arg method "$method" --arg password "$password" \
            '{tag:$tag,type:"shadowsocks",server:$server,server_port:$port,method:$method,password:$password}')
        ;;
    hysteria2 | hy2)
        if [[ $authority != *@* ]]; then
            ob_error "Hysteria2 链接缺少密码与服务器地址分隔符 @。"
            return 1
        fi
        userinfo=${authority%@*}
        host_port=${authority##*@}
        host_port=${host_port%/}
        ob_url_decode "$userinfo"
        password=$ob_decoded
        [[ $password ]] || {
            ob_error "Hysteria2 密码不能为空。"
            return 1
        }
        ob_parse_link_host_port "$host_port" || return 1
        alpn=
        insecure=
        pin=
        obfs=
        obfs_password=
        sni=
        while [[ $query ]]; do
            pair=${query%%&*}
            if [[ $query == *'&'* ]]; then query=${query#*'&'}; else query=; fi
            [[ $pair == *=* ]] || continue
            key=${pair%%=*}
            value=${pair#*=}
            ob_url_decode "$key"
            key=$ob_decoded
            ob_url_decode "$value"
            value=$ob_decoded
            case $key in
            alpn) alpn=$value ;;
            insecure | allowInsecure) insecure=$value ;;
            pinSHA256) pin=$value ;;
            obfs) obfs=$value ;;
            obfs-password | obfs_password) obfs_password=$value ;;
            sni | peer) sni=$value ;;
            esac
        done
        tls=$(jq -n '{enabled:true}')
        if [[ $alpn ]]; then
            alpn_json=$(jq -Rn --arg value "$alpn" '$value | split(",") | map(select(length > 0))') || return 1
            tls=$(jq --argjson alpn "$alpn_json" '. + {alpn:$alpn}' <<<"$tls")
        fi
        if [[ ${insecure,,} == 1 || ${insecure,,} == true ]]; then
            tls=$(jq '. + {insecure:true}' <<<"$tls")
        fi
        if [[ $sni ]]; then
            tls=$(jq --arg server_name "$sni" '. + {server_name:$server_name}' <<<"$tls")
        fi
        if [[ $pin ]]; then
            pin_hex=${pin//:/}
            if [[ ${#pin_hex} -eq 64 && $pin_hex =~ ^[[:xdigit:]]+$ ]]; then
                pin_hex=${pin_hex,,}
                pin_base64=$(for ((i = 0; i < 64; i += 2)); do printf '%b' "\\x${pin_hex:i:2}"; done | base64 -w 0)
            elif [[ $pin =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && printf '%s' "$pin" | base64 --decode >/dev/null 2>&1 && [[ $(printf '%s' "$pin" | base64 --decode 2>/dev/null | wc -c) -eq 32 ]]; then
                pin_base64=$pin
            else
                ob_error "Hysteria2 pinSHA256 必须是 64 位十六进制指纹或 Base64 SHA-256。"
                return 1
            fi
            tls=$(jq --arg pin "$pin_base64" '. + {certificate_sha256:[$pin]}' <<<"$tls")
        fi
        if [[ $obfs ]]; then
            [[ $obfs_password ]] || {
                ob_error "设置 Hysteria2 obfs 时必须同时提供 obfs-password。"
                return 1
            }
            ob_json=$(jq -n --arg tag "${fragment:-hysteria2-$ob_server-$ob_port}" --arg server "$ob_server" --argjson port "$ob_port" --arg password "$password" --argjson tls "$tls" --arg obfs "$obfs" --arg obfs_password "$obfs_password" \
                '{tag:$tag,type:"hysteria2",server:$server,server_port:$port,password:$password,tls:$tls,obfs:{type:$obfs,password:$obfs_password}}')
        else
            ob_json=$(jq -n --arg tag "${fragment:-hysteria2-$ob_server-$ob_port}" --arg server "$ob_server" --argjson port "$ob_port" --arg password "$password" --argjson tls "$tls" \
                '{tag:$tag,type:"hysteria2",server:$server,server_port:$port,password:$password,tls:$tls}')
        fi
        ;;
    *)
        ob_error "暂不支持链接协议: $scheme。仅支持 ss://、hysteria2:// 和 hy2://。"
        return 1
        ;;
    esac
}

ob_add_outbound_link() {
    ob_read "粘贴 Shadowsocks 或 Hysteria2 链接: " || return 1
    ob_parse_outbound_link "$ob_value" || return 1
    ob_show_json "$ob_json"
    if jq -e --arg tag "$(jq -r '.tag' <<<"$ob_json")" 'any(.outbounds[]?; .tag == $tag)' "$ob_config" >/dev/null; then
        ob_error "出站名称已存在: $(jq -r '.tag' <<<"$ob_json")"
        return 1
    fi
    ob_save '.outbounds += [$entry]' --argjson entry "$ob_json"
}

ob_add_outbound() {
    ob_read_outbound || return
    if jq -e --arg tag "$(jq -r '.tag' <<<"$ob_json")" 'any(.outbounds[]?; .tag == $tag)' "$ob_config" >/dev/null; then
        ob_error "出站名称已存在。"
        return 1
    fi
    ob_save '.outbounds += [$entry]' --argjson entry "$ob_json"
}

ob_edit_outbound() {
    local old_tag new_tag
    ob_pick_outbound || return
    old_tag=$ob_selected_tag
    if [[ $(jq -r '.type' <<<"$ob_selected") != http && $(jq -r '.type' <<<"$ob_selected") != socks ]]; then
        ob_error "此入口仅支持编辑 HTTP 和 SOCKS 出站。"
        return 1
    fi
    ob_read_outbound "$ob_selected" || return
    new_tag=$(jq -r '.tag' <<<"$ob_json")
    if jq -e --arg tag "$new_tag" --argjson index "$ob_index" 'any(.outbounds | to_entries[]; .key != $index and .value.tag == $tag)' "$ob_config" >/dev/null; then
        ob_error "出站名称已被使用。"
        return 1
    fi
    ob_save '.outbounds[$index] = $entry
        | if $old != $new and has("route") then
            .route |= (if .final == $old then .final = $new else . end
                | .rules = [(.rules // [])[] | if .outbound == $old then .outbound = $new else . end])
          else . end' \
        --argjson index "$ob_index" --arg old "$old_tag" --arg new "$new_tag" --argjson entry "$ob_json"
}

ob_add_rule() {
    local rule_type outbound set_final
    msg "规则类型："
    msg "1) 将入站流量转发到出站"
    msg "2) 自定义规则（例如 sniff）"
    echo -ne "请选择 [1-2]: "
    IFS= read -r rule_type || return
    case $rule_type in
    1)
        ob_pick_inbounds || return
        ob_pick_outbound || return
        outbound=$ob_selected_tag
        [[ $outbound ]] || {
            ob_error "目标出站没有 tag，无法创建规则。"
            return 1
        }
        ob_json=$(jq -n --argjson inbound "$ob_selected_inbounds" --arg outbound "$outbound" \
            '{inbound:$inbound,action:"route",outbound:$outbound}')
        ;;
    2)
        outbound=
        ob_build_sniff_rule || return
        ;;
    *)
        msg "已取消。"
        return 1
        ;;
    esac
    ob_show_json "$ob_json"
    ob_validate_rule || return
    if [[ $(jq -r '.action' <<<"$ob_json") == route ]]; then
        outbound=$(jq -r '.outbound' <<<"$ob_json")
    else
        outbound=
    fi
    if [[ $outbound ]]; then
        echo -ne "同时设为未匹配流量的默认出站？[y/N]: "
        IFS= read -r set_final
        if [[ ${set_final,,} == y || ${set_final,,} == yes ]]; then
            ob_save '.route = (.route // {}) | .route.rules = ((.route.rules // []) + [$rule]) | .route.final = $final' --argjson rule "$ob_json" --arg final "$outbound"
            return
        fi
    fi
    ob_save '.route = (.route // {}) | .route.rules = ((.route.rules // []) + [$rule])' --argjson rule "$ob_json"
}

ob_validate_rule() {
    local outbound inbound_tags inbound_tag
    jq -e 'type == "object"' <<<"$ob_json" >/dev/null || {
        ob_error "规则必须是 JSON 对象。"
        return 1
    }
    if ! jq -e '.action | type == "string" and length > 0' <<<"$ob_json" >/dev/null; then
        if jq -e 'has("outbound") and (has("action") | not)' <<<"$ob_json" >/dev/null; then
            ob_json=$(jq '. + {action:"route"}' <<<"$ob_json")
            msg "旧版 outbound 规则已自动迁移为 action=route。"
        else
            ob_error "规则必须包含非空 action 字段。"
            return 1
        fi
    fi
    outbound=$(jq -r '.outbound // empty' <<<"$ob_json")
    if [[ $(jq -r '.action' <<<"$ob_json") == route ]]; then
        if ! jq -e '.outbound | type == "string" and length > 0' <<<"$ob_json" >/dev/null || ! jq -e --arg tag "$outbound" 'any(.outbounds[]?; .tag == $tag)' "$ob_config" >/dev/null; then
            ob_error "route 规则必须引用一个有效的 outbound tag。"
            return 1
        fi
    elif [[ $outbound ]]; then
        ob_error "只有 action=route 的规则才能设置 outbound。"
        return 1
    fi
    if jq -e 'has("inbound")' <<<"$ob_json" >/dev/null; then
        if ! jq -e '.inbound | if type == "array" then length > 0 and all(.[]; type == "string" and length > 0) else type == "string" and length > 0 end' <<<"$ob_json" >/dev/null; then
            ob_error "规则至少需要选择一个 inbound tag。"
            return 1
        fi
        inbound_tags=$(ob_inbound_tags | jq -R . | jq -s .)
        while IFS= read -r inbound_tag; do
            [[ ! $inbound_tag ]] && continue
            if ! jq -e --arg tag "$inbound_tag" 'index($tag) != null' <<<"$inbound_tags" >/dev/null; then
                ob_error "规则引用了不存在的入站 tag: $inbound_tag"
                return 1
            fi
        done < <(jq -r '.inbound | if type == "array" then .[] else . end' <<<"$ob_json")
    fi
}

ob_edit_rule() {
    local rule_index rule_type outbound
    ob_pick_rule || return
    rule_index=$ob_index
    msg "规则类型："
    msg "1) 将入站流量转发到出站"
    msg "2) 协议嗅探 (sniff)"
    echo -ne "请选择 [1-2]: "
    IFS= read -r rule_type || return
    case $rule_type in
    1)
        ob_pick_inbounds || return
        ob_pick_outbound || return
        outbound=$ob_selected_tag
        [[ $outbound ]] || {
            ob_error "目标出站没有 tag，无法设置转发规则。"
            return 1
        }
        ob_json=$(jq -n --argjson inbound "$ob_selected_inbounds" --arg outbound "$outbound" \
            '{inbound:$inbound,action:"route",outbound:$outbound}')
        ;;
    2)
        ob_build_sniff_rule || return
        ;;
    *)
        msg "已取消。"
        return 1
        ;;
    esac
    ob_show_json "$ob_json"
    ob_validate_rule || return
    ob_save '.route.rules[$index] = $rule' --argjson index "$rule_index" --argjson rule "$ob_json"
}

ob_delete_outbound() {
    ob_pick_outbound || return
    local tag=$ob_selected_tag
    if jq -e --arg tag "$tag" '(.route.final == $tag) or any(.route.rules[]?; .outbound == $tag)' "$ob_config" >/dev/null; then
        ob_error "出站 $tag 正被默认出口或路由规则引用，请先编辑或删除相关规则。"
        return 1
    fi
    ob_save 'del(.outbounds[$index])' --argjson index "$ob_index"
}

ob_delete_rule() {
    ob_pick_rule || return
    ob_save 'del(.route.rules[$index])' --argjson index "$ob_index"
}

outbound_menu() {
    ob_config_ready || return
    while :; do
        msg "\n------------- 出站与路由管理 -------------"
        msg "1) 添加出站"
        msg "2) 编辑出站"
        msg "3) 添加规则"
        msg "4) 编辑规则"
        msg "5) 删除出站"
        msg "6) 删除规则"
        msg "7) 通过链接添加 Shadowsocks / Hysteria2 出站"
        msg "0) 返回"
        echo -ne "请选择: "
        IFS= read -r answer || return
        case $answer in
        1) ob_add_outbound ;;
        2) ob_edit_outbound ;;
        3) ob_add_rule ;;
        4) ob_edit_rule ;;
        5) ob_delete_outbound ;;
        6) ob_delete_rule ;;
        7) ob_add_outbound_link ;;
        0|'') return ;;
        *) msg "请输入 0 到 7。" ;;
        esac
    done
}

outbound_menu
