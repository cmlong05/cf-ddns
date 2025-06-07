#!/bin/bash
# 设置 PATH 环境变量，确保系统能找到常用命令
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# 需要修改的部分
# 读取配置文件
CONFIG_FILE="$(dirname "$(realpath "$0")")/cf-config.ini"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Config file $CONFIG_FILE not found."
    exit 1
fi

# 日志函数，记录带时间戳的日志信息
log() {
    if [ -n "$1" ]; then
        echo -e "[$(date)] - $1" >> "$cloudflare_log"
    fi
}

# 检查必要变量是否为空
check_variables() {
    local vars=("auth_email" "auth_key" "zone_name" "record_name" "record_type" "zone_identifier_file" "record_identifier_file" "cloudflare_log" "sender_email")
    for var in "${vars[@]}"; do
        if [ -z "${!var}" ]; then
            log "Error: $var is not set."
            exit 1
        fi
    done
    # 当 sender_email 为 1 时，检查 recipient_email
    if [ "$sender_email" = "1" ] && [ -z "$recipient_email" ]; then
        log "Error: recipient_email is not set while sender_email is true."
        exit 1
    fi
    # record_type 包含 A 时，检测 ipv4_file 
    if [[ "$record_type" =~ A ]] && [ -z "${ipv4_file}" ]; then
        log "Error: ipv4_file is not set"
        exit 1
    fi
    # record_type 包含 AAAA 时，检测 ipv6_file 
    if [[ "$record_type" =~ AAAA ]] && [ -z "${ipv4_file}"  ]; then
        log "Error: ipv6_file is not set "
        exit 1
    fi
}

# 获取当前 IP 地址
get_ipv6_address() {
    local ipv6=$(ip route get 1:: | awk '{print $(NF-4);exit}')
    if [ -z "$ip" ]; then
        log "no ipv6 address get，print ip a, then reload wlan0"
        exit 2
    fi
    echo "$ip"
}
get_ipv4_address() {
    local ipv4=$(wget -qO- checkip.amazonaws.com)
    if [ -z "$ipv4" ]; then
        log "no ipv4 address get，print ip a, then reload wlan0"
        exit 2
    fi
    echo "$ipv4"
}

# 检查 IP 地址是否变化（支持 IPv4/IPv6，参数1为新IP，参数2为类型A或AAAA）
check_ip_change() {
    local new_ip="$1"
    local type="$2"
    local ip_file
    if [ "$type" = "A" ]; then
        ip_file="$ipv4_file"
    elif [ "$type" = "AAAA" ]; then
        ip_file="$ipv6_file"
    else
        log "Unknown IP type: $type"
        exit 4
    fi

    if [ -f "$ip_file" ]; then
        local old_ip
        old_ip=$(cat "$ip_file")
        if [ "$new_ip" = "$old_ip" ]; then
            echo -e "IP has not changed." >> "$cloudflare_log"
            exit 3
        fi
    fi
}

# 获取区域和记录标识符
get_identifiers() {
    # 检查 zone_identifier_file 和 record_identifier_file 是否存在且内容不为空
    if [ -f "$zone_identifier_file" ] && [ -s "$zone_identifier_file" ] && \
       [ -f "$record_identifier_file" ] && [ -s "$record_identifier_file" ]; then
        local zone_identifier=$(cat "$zone_identifier_file")
        local record_identifier=$(cat "$record_identifier_file")
        echo "successfully read identifiers from files"
        echo "$zone_identifier $record_identifier"
    else
        local zone_identifier=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name" \
            -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json" | jq -r '.result[0].id')
        local record_identifier=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records?name=$record_name" \
            -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json" | jq -r '.result[0].id')

        echo "$zone_identifier" > "$zone_identifier_file"
        echo "$record_identifier" > "$record_identifier_file"
        echo "$zone_identifier $record_identifier"
    fi
}
# 发送邮件通知
send_email() {
    local recipient="$1"
    local ipv4="$2"
    local ipv6="$3"
    if [ -z "$recipient" ]; then
        log "Error: Recipient email is not provided."
        return 1
    fi
    echo "send mail start"
    echo -e "Subject: Raspian Changed\n\nIPv4: $ipv4\nIPv6: $ipv6" | msmtp -a default "$recipient"
    echo "send mail finished"
}

# 更新 Cloudflare DNS 记录
update_dns_records() {
    local zone_identifier="$1"
    local record_identifier="$2"
    local ip="$3"
    local type="$4"
    local ip_file

    if [ "$type" = "A" ]; then
        ip_file="$ipv4_file"
    elif [ "$type" = "AAAA" ]; then
        ip_file="$ipv6_file"
    else
        log "Unknown IP type: $type"
        exit 4
    fi

    echo 'start update'
    local update=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/$record_identifier" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json" --data "{\"id\":\"$zone_identifier\",\"type\":\"$type\",\"name\":\"$record_name\",\"content\":\"$ip\"}")

    # 记录响应日志
    echo "updating response"
    if [[ $update == *"\"success\":false"* ]]; then
        local message="API UPDATE FAILED. DUMPING RESULTS:\n$update"
        log "$message"
        echo -e "$message"
        exit 7
    else
        local message="IP changed to: $ip"
        log "$message"
        echo "$ip" > "$ip_file"
        echo -e "$message"
    fi
}

# 主函数，脚本执行入口
main() {
    local type="$1"
    if [ -z "$type" ]; then
        log "Error: No type specified. Use 'A' for IPv4 or 'AAAA' for IPv6."
        exit 1
    fi

    if [[ "$type" != "A" && "$type" != "AAAA" ]]; then
        log "Error: Invalid type specified. Use 'A' for IPv4 or 'AAAA' for IPv6."
        exit 1
    fi
    log "Starting Cloudflare DDNS update for type: $type"
    # 获取当前 IP 地址
    if [ "$type" = "A" ]; then
        local ip=$(get_ipv4_address)
        check_ip_change "$ip" "A"
    elif [ "$type" = "AAAA" ]; then
        local ip=$(get_ipv6_address)
        check_ip_change "$ip" "AAAA"
    fi

    # 获取zone和记录标识符
    IFS=' ' read -r zone_identifier record_identifier <<< "$(get_identifiers)"
    echo "zone_identifier: $zone_identifier"
    echo "record_identifier: $record_identifier"

    # 更新 DNS 记录
    update_dns_records "$zone_identifier" "$record_identifier" "$ip" "$type"

    # 发送邮件通知
    if [ "$sender_email" = "1" ]; then
        send_email "$recipient_email" "$ip"
    else
        log "Email sending is disabled."
    fi
    # 保持日志文件大小
    echo "$(tail -n 100 "$cloudflare_log")" > "$cloudflare_log"
}

# 检查必要变量
check_variables

# 执行主函数循环record_type
for type in $record_type; do
    main "$type"
done


