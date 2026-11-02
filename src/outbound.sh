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

ob_edit_json() {
    local value=$1 file editor
    ob_json=$value
    msg "\n4. 检查并修改生成的 JSON"
    jq . <<<"$ob_json"
    editor=${EDITOR:-vi}
    file=$(mktemp) || {
        ob_error "无法创建 JSON 临时文件。"
        return 1
    }
    jq . <<<"$ob_json" >"$file"
    if ! "$editor" "$file"; then
        rm -f "$file"
        ob_error "编辑器退出失败，操作已取消。"
        return 1
    fi
    if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
        rm -f "$file"
        ob_error "JSON 无效，操作已取消。"
        return 1
    fi
    ob_json=$(<"$file")
    rm -f "$file"
}

ob_save() {
    local filter=$1 tmp backup mode
    shift
    tmp=$(mktemp "${ob_config}.tmp.XXXXXX") || {
        ob_error "无法创建临时配置文件。"
        return 1
    }
    if ! jq "$@" "$filter" "$ob_config" >"$tmp"; then
        rm -f "$tmp"
        ob_error "更新配置失败，原配置未修改。"
        return 1
    fi
    if ! "$is_core_bin" check -c "$tmp" -C "$is_conf_dir"; then
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
        echo -ne "用户名 (回车保留，输入 - 删除认证): "
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
            '$old * $generated | if $remove_auth == "1" or ($generated | has("username") | not) then del(.username, .password) else . end')
    fi
    ob_edit_json "$ob_json" || return 1
    jq -e '(.tag | type == "string" and length > 0) and (.type == "http" or .type == "socks") and (.server | type == "string" and length > 0) and (.server_port | type == "number" and . > 0 and . <= 65535)' <<<"$ob_json" >/dev/null || {
        ob_error "出站 JSON 缺少有效 tag、类型、服务器地址或端口。"
        return 1
    }
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
    ob_pick_inbounds || return
    msg "规则类型："
    msg "1) 将入站流量转发到出站"
    msg "2) 自定义规则（例如 sniff）"
    echo -ne "请选择 [1-2]: "
    IFS= read -r rule_type || return
    case $rule_type in
    1)
        ob_pick_outbound || return
        outbound=$ob_selected_tag
        [[ $outbound ]] || {
            ob_error "目标出站没有 tag，无法创建规则。"
            return 1
        }
        ob_json=$(jq -n --argjson inbound "$ob_selected_inbounds" --arg outbound "$outbound" \
            '{inbound:$inbound,outbound:$outbound}')
        ;;
    2)
        outbound=
        ob_json=$(jq -n --argjson inbound "$ob_selected_inbounds" \
            '{inbound:$inbound,action:"sniff",sniffer:["http","tls","quic"]}')
        ;;
    *)
        msg "已取消。"
        return 1
        ;;
    esac
    ob_edit_json "$ob_json" || return
    ob_validate_rule || return
    if [[ $outbound ]]; then
        echo -ne "同时设为未匹配流量的默认出站？[y/N]: "
        IFS= read -r set_final
        if [[ ${set_final,,} == y || ${set_final,,} == yes ]]; then
            ob_save '.route = (.route // {}) | .route.rules = ((.route.rules // []) + [$rule]) | .route.final = $final' --argjson rule "$ob_json" --arg final "$outbound"
            return
        fi
    fi
    ob_save '.route = (.route // {}) | .route.rules = (if ($rule | has("action")) then [$rule] + (.route.rules // []) else (.route.rules // []) + [$rule] end)' --argjson rule "$ob_json"
}

ob_validate_rule() {
    local outbound inbound_tags inbound_tag
    jq -e 'type == "object"' <<<"$ob_json" >/dev/null || {
        ob_error "规则必须是 JSON 对象。"
        return 1
    }
    outbound=$(jq -r '.outbound // empty' <<<"$ob_json")
    if [[ $outbound ]] && ! jq -e --arg tag "$outbound" 'any(.outbounds[]?; .tag == $tag)' "$ob_config" >/dev/null; then
        ob_error "规则引用了不存在的出站 tag: $outbound"
        return 1
    fi
    if ! jq -e 'has("action") or has("outbound")' <<<"$ob_json" >/dev/null; then
        ob_error "规则必须包含 action 或 outbound。"
        return 1
    fi
    if jq -e 'has("inbound")' <<<"$ob_json" >/dev/null; then
        if ! jq -e '(.inbound | type) == "string" or (.inbound | type) == "array"' <<<"$ob_json" >/dev/null; then
            ob_error "inbound 必须是 tag 字符串或字符串数组。"
            return 1
        fi
        if ! jq -e '.inbound | if type == "array" then length > 0 else length > 0 end' <<<"$ob_json" >/dev/null; then
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
    local rule_index
    ob_pick_rule || return
    rule_index=$ob_index
    ob_edit_json "$ob_selected_rule" || return
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
        0|'') return ;;
        *) msg "请输入 0 到 6。" ;;
        esac
    done
}

outbound_menu
