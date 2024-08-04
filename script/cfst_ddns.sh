#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
# --------------------------------------------------------------
#	项目: CloudflareSpeedTest 自动更新域名解析记录
#	版本: 1.0.4
#	作者: XIU2
#	项目: https://github.com/XIU2/CloudflareSpeedTest
# --------------------------------------------------------------

CURRENTIP=0.0.0.0
CURRENTSPEED=0
RECALLMSG=0
declare -a DNS_RECORD_IDS=()

TEMP_FILE=$(mktemp)
exec > >(tee -a "${TEMP_FILE}") 2>&1

read_config() {
  if [[ -f cfst_ddns.conf ]]; then
    source cfst_ddns.conf

    if [[ -n "${TG_LAST_MSG_ID}" ]]; then
      RECALLMSG=1
      echo "  TG撤回消息开关: ON "
    else
      echo "  TG撤回消息开关: OFF "
    fi

  else
    echo "  cfst_ddns.conf 文件不存在，请使用以下命令从模板创建:"
    echo "  cp cfst_ddns.conf.template cfst_ddns.conf"
    exit 1
  fi
}

retrive_dns_record_id() {
  echo "  查询DNS RECORD ID:"
  ALL_RECORDS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            -H "X-Auth-Key: $KEY" \
            -H "X-Auth-Email: $EMAIL" \
            -H "Content-Type: application/json")
  for DOMAIN in "${MYDOMAINS[@]}"; do
    RECORD_ID=$(echo $ALL_RECORDS | jq -r '.result[] | select(.name == "'"$DOMAIN"'") | .id')
    if [[ -n "$RECORD_ID" ]]; then
      echo "  $DOMAIN -> $RECORD_ID"
      DNS_RECORD_IDS+=("$RECORD_ID")
    fi

  done

}

notify_tg()
{
   if [[ -n "$1"  ]]; then

    if [[ $RECALLMSG == 1 ]]; then
      echo -n "  TG撤回消息[$TG_LAST_MSG_ID]... "
      res=$(timeout 20s curl -s -X POST $TG_URL/deleteMessage \
            -d chat_id=${TG_USER_ID} \
            -d message_id=${TG_LAST_MSG_ID})
      isSuccess=$(echo $res | jq -r ' .result')
      if [ "$isSuccess" == "true" ]; then
        echo "  成功"
      else
        echo "  失败 $res"
      fi
    fi

    res=$(timeout 20s curl -s -X POST $TG_URL/sendMessage \
            -d chat_id=${TG_USER_ID} \
            -d parse_mode=${TG_MODE} \
            -d text="$1" 2>&1)

    if [ $? == 124 ]; then
      echo "  $TG_URL 请求超时,请检查网络是否重启完成并是否能够访问TG"
      exit 1
    fi
    
    resSuccess=$(echo "$res" | jq -r ".ok")
    TG_LAST_MSG_ID=$(echo "$res" | jq -r ".result.message_id")
    if [[ $resSuccess = "true" ]]; then
      echo "  TG推送成功 MSGID [$TG_LAST_MSG_ID]"
      # even if the switch is OFF, we can still update latest msg id
      # ^\s* matches any leading whitespace at the start of the line
      # ? optionally matches a # character (indicating a commented line).
      # \s* matches any whitespace following the optional #.
      # TG_LAST_MSG_ID=.*$ matches the rest of the line that sets TG_LAST_MSG_ID
      sed -i "s|^\(\s*#\?.*TG_LAST_MSG_ID=\).*|\1${new_TG_LAST_MSG_ID}|" cfst_ddns.conf

    else
      echo "  notify_tg failed: "
      echo "$res" | jq
    fi
  fi
}


test_current()
{
  ## TODO: now, only test the first domain
  CURRENTIP=$(nslookup ${MYDOMAINS[0]} 1.1.1.1 | \
              grep "Address: "| awk -F': ' '{ print $2 }')

  echo "  准备测速 $CURRENTIP"
  #in case the current IP is not reachable, CFST will not create 
  #CURRENTSPEED.tmp file, thus the old file would be read later. 
  #So we need to rm it
  if [ -f CURRENTSPEED.tmp ]; then 
    rm CURRENTSPEED.tmp
  fi

  ./CloudflareST \
    -dt $TESTLENGTH \
    -url $TESTURL \
    -o CURRENTSPEED.tmp \
    -ip $CURRENTIP \
    > /dev/null 2>&1

  if [ -f CURRENTSPEED.tmp ]; then
    CURRENTSPEED=$(cat CURRENTSPEED.tmp |awk -F',' 'NR==2 {print $6}')
  else
    CURRENTSPEED=0
  fi

#echo "  当前车速: $CURRENTSPEED MB/s" 

}

update_hosts() {

  DOMAIN="$1"
  NEW_IP="$2"
  HOSTS_FILE="/etc/hosts"

  # Backup the hosts file
  cp $HOSTS_FILE  ${HOSTS_FILE}.bak

  # Check if the DOMAIN exists in the hosts file
  if grep -q "$DOMAIN" $HOSTS_FILE; then
    sed -i.bak "s/^.*$DOMAIN\$/$NEW_IP $DOMAIN/" $HOSTS_FILE
    echo "  $NEW_IP for $DOMAIN updated successfully in $HOSTS_FILE"
  else
    echo "  $NEW_IP $DOMAIN" >> $HOSTS_FILE
    echo "  DOMAIN $DOMAIN added to $HOSTS_FILE with IP $NEW_IP"
  fi

}


test_and_update() 
{

  # if CFST fails to create NEWSPEED.tmp, avoid reading the old one
  if [ -f NEWSPEED.tmp ]; then
    rm NEWSPEED.tmp
  fi
  
  # 这里可以自己添加、修改 CloudflareST 的运行参数
  ./CloudflareST \
      -url $TESTURL \
      -dt $TESTLENGTH \
      -t 1 -n 500 -p 1 -tp 443 \
      -dn $TARGETNUMBEROFIP \
      -sl $TARGETSPEED \
      -tl 250 -tll 40 \
      -o "NEWSPEED.tmp" \
      > /dev/null 2>&1


  
  # if [[ -z "${NEWIP1}" || -z "${NEWIP2}" || -z "${NEWIP3}" || -z "${NEWIP4}" || -z "${NEWIP5}" ]]; then
  #     echo "  CloudflareST 测速结果 IP 数量为 0，跳过下面步骤..."
  #     exit 0
  # fi

  declare -a NEWIPS=()
  declare -a NEWSPEEDS=()

  for index in "${!MYDOMAINS[@]}"; do
    echo "  MYDOMAINS[$index] = ${MYDOMAINS[$index]}"
    let ROWNUM=2+$index
    NEWIPS[$index]=$(sed -n "$ROWNUM,1p" NEWSPEED.tmp | awk -F, '{print $1}')
    NEWSPEEDS[$index]=$(sed -n "$ROWNUM,1p" NEWSPEED.tmp | awk -F, '{print $6}')
    
    # echo ${NEWIPS[0]} >> result_archive.txt

    echo "  优选成功，准备更新hosts文件${NEWIPS[$index]}@${NEWSPEEDS[$index]} to ${MYDOMAINS[$index]} ID=${DNS_RECORD_IDS[$index]}"
    update_hosts  ${MYDOMAINS[$index]} ${NEWIPS[$index]}

    echo "  优选成功，准备更新${NEWIPS[$index]}@${NEWSPEEDS[$index]} to ${MYDOMAINS[$index]}"
    DDNS_RESULT=$(timeout 20s curl -s \
      -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${DNS_RECORD_IDS[$index]}" \
      -H "X-Auth-Email: ${EMAIL}" \
      -H "X-Auth-Key: ${KEY}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"${TYPE}\",\"name\":\"${MYDOMAINS[$index]}\",\"content\":\"${NEWIPS[$index]}\",\"ttl\":${TTL},\"proxied\":${PROXIED}}" )
    if [ $? == 124 ]; then
      echo '  DDNS请求超时,请检查网络是否重启完成并是否能够访问api.cloudflare.com'
      exit 1
    fi

    IS_SUCCESS=$(echo "$DDNS_RESULT" | jq -r ".success")
    if [[ $IS_SUCCESS = "true" ]]; then
      echo "  DDNS更新成功"
    else
      echo "  DDNS更新失败请检查:"
      echo "$DDNS_RESULT" | jq
      exit 1
    fi
  done

}



handle_exit(){
  
  if [ "$last_tcp_mode" != "disable" ]; then
    uci set "passwall.@global[0].tcp_proxy_mode"=$last_tcp_mode
    uci commit
    echo "  TCP默认代理 = $last_tcp_mode"
  fi
  date "+<<<< Goodbye %m/%d %H:%M:%S <<<<"
}

main(){
  date "+>>>> Hello   %m/%d %H:%M:%S >>>>"
  trap handle_exit EXIT HUP INT TERM
  last_tcp_mode=$(uci get "passwall.@global[0].tcp_proxy_mode")
  echo "  TCP默认代理 = $last_tcp_mode"
    
  if [ "$last_tcp_mode" != "disable" ]; then
    uci set "passwall.@global[0].tcp_proxy_mode"='disable'
    uci commit
    echo "  TCP默认代理 = Disabled"
  fi

  read_config
  retrive_dns_record_id
  
  if [ "$SKIP_TEST_CURRENT" = false ]; then
    test_current
  else
    echo "  SKIP_TEST_CURRENT is true, CURRENTSPEED shall be 0"
  fi

  if (( $(echo "$CURRENTSPEED < $TARGETSPEED" | bc -l)  )); then
    echo "  当前车速 $CURRENTIP @ $CURRENTSPEED MB/s < 目标车速 $TARGETSPEED MB/s, 准备测速"
    test_and_update
  else
    echo "  当前车速 $CURRENTIP @ $CURRENTSPEED > 目标车速 $TARGETSPEED, 跳过测速"
    
  fi

  
  notify_tg "$(cat "${TEMP_FILE}")"

  # Clean up
  rm "${TEMP_FILE}"

} 


main


