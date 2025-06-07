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
    local vars=("auth_email" "auth_key" "zone_name" "record_name" "ip_file" "id_file" "cloudflare_log" "sender_email")
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
}

# 获取当前 IPv6 地址
get_ipv6_address() {
    local ip=$(ip route get 1:: | awk '{print $(NF-4);exit}')
    if [ -z "$ip" ]; then
        log "no ipv6 address get，print ip a, then reload wlan0"
        exit 2
    fi
    echo "$ip"
}

# 检查 IPv6 地址是否变化
check_ip_change() {
    local new_ip="$1"
    if [ -f "$ip_file" ]; then
        local old_ip=$(cat "$ip_file")
        if [ "$new_ip" = "$old_ip" ]; then
            echo -e "IP has not changed." >> "$cloudflare_log"
            exit 3
        fi
    fi
}

# 获取区域和记录标识符
get_identifiers() {
    if [ -f "$id_file" ] && [ "$(wc -l "$id_file" | cut -d " " -f 1)" -eq 3 ]; then
        source "$id_file"
        local zone_identifier=$($zone_name)
        local record_identifier=$($record_name)
        echo "successfully read identifiers from $id_file"
        echo "$zone_identifier $record_identifier"
        exit 0
    else
        local zone_identifier=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json" | jq -r '.result[0].id')
        local record_identifier=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records?name=$record_name" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json" | jq -r '.result[0].id')

        echo "$zone_name="$zone_identifier"" > "$id_file"
        echo "$record_name="$$record_identifier"" >> "$id_file"
        echo "$zone_identifier $record_identifier"
    fi
}

# 发送邮件通知
send_email() {
    local recipient="$1"
    if [ -z "$recipient" ]; then
        log "Error: Recipient email is not provided."
        return 1
    fi
    local ipa=$(ip a)
    local iproute=$(ip route get 1::)
    echo "send mail start"
    echo -e "Subject: Raspian Changed \n\n Route \n $iproute \n $ipa" | msmtp -a default "$recipient"
    echo "send mail finished"
}

# 更新 Cloudflare DNS 记录
update_dns_records() {
    local zone_identifier="$1"
    local record_identifier="$2"
    local ip="$3"

    echo 'start update'
    local update=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/$record_identifier" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json" --data "{\"id\":\"$zone_identifier\",\"type\":\"AAAA\",\"name\":\"$record_name\",\"content\":\"$ip\",\"proxied\":true}")

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
    check_variables
    local ip=$(get_ipv6_address)
    check_ip_change "$ip"
    IFS=' ' read -r zone_identifier record_identifier <<< "$(get_identifiers)"
    echo "zone_identifier: $zone_identifier"
    echo "record_identifier: $record_identifier"
    if [ "$sender_email" = "1" ]; then
        send_email "$recipient_email"
    else
        log "Email sending is disabled."
    fi
    update_dns_records "$zone_identifier" "$record_identifier" "$ip"
    # 保持日志文件大小
    echo "$(tail -n 100 "$cloudflare_log")" > "$cloudflare_log"
}

# 日志记录脚本检查开始
log "Check Initiated"
# 执行主函数
main