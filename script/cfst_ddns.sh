#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
# --------------------------------------------------------------
#	项目: CloudflareSpeedTest 自动更新域名解析记录
#	版本: 1.0.4
#	作者: XIU2
#	项目: https://github.com/XIU2/CloudflareSpeedTest
# --------------------------------------------------------------

read_config() {
  if [[ -f cfst_ddns.conf ]]; then
    source cfst_ddns.conf
  else
    echo "cfst_ddns.conf 文件不存在，请使用以下命令从模板创建:"
    echo "cp cfst_ddns.conf.template cfst_ddns.conf"
    exit 1
  fi
}

CURRENTIP=0.0.0.0
CURRENTSPEED=0

notify_tg()
{
  echo "$1"
  if [[ $NOTIFY_TG -eq 1 ]]; then

    if [[ -n "${TG_LAST_MSG_ID}" ]]; then
      echo -n "  TG撤回消息[$TG_LAST_MSG_ID]成功 = "
      res=$(timeout 20s curl -s -X POST $TG_URL/deleteMessage \
            -d chat_id=${TG_USER_ID} \
            -d message_id=${TG_LAST_MSG_ID})
      echo $res | jq -r ' .result'
    fi

    res=$(timeout 20s curl -s -X POST $TG_URL/sendMessage \
            -d chat_id=${TG_USER_ID} \
            -d parse_mode=${TG_MODE} \
            -d text="$1")

    if [ $? == 124 ]; then
      echo "  $TG_URL 请求超时,请检查网络是否重启完成并是否能够访问TG"
      exit 1
    fi
    
    resSuccess=$(echo "$res" | jq -r ".ok")
    TG_LAST_MSG_ID=$(echo "$res" | jq -r ".result.message_id")
    if [[ $resSuccess = "true" ]]; then
      echo "  TG推送成功 MSGID [$TG_LAST_MSG_ID]"
      sed -i "s/^TG_LAST_MSG_ID=.*$/TG_LAST_MSG_ID=$TG_LAST_MSG_ID/" cfst_ddns.conf
    else
      echo "  TG推送失败，请检查返回消息: "
      echo "$res" | jq
    fi
  fi
}


test_current()
{
  
  CURRENTIP=$(nslookup $NAME 1.1.1.1 | \
              grep "Address: "| awk -F': ' '{ print $2 }')

  echo "  准备测速 $CURRENTIP"

  ./CloudflareST \
     -dt $TESTLENGTH \
     -url $TESTURL \
     -o CURRENTSPEED.tmp \
     -ip $CURRENTIP \
     > /dev/null 2>&1

  CURRENTSPEED=$(cat CURRENTSPEED.tmp |awk -F',' 'NR==2 {print $6}')

  echo "  当前车速: $CURRENTSPEED MB/s" 
}

test_and_update() 
{

  # 这里可以自己添加、修改 CloudflareST 的运行参数
  ./CloudflareST \
      -url $TESTURL \
      -dt $TESTLENGTH \
      -t 1 -n 500 -p 1 -tp 443 \
      -dn $TARGETNUMBEROFIP \
      -sl $TARGETSPEED \
      -tl 250 -tll 40 \
      -o "NEWSPEED.tmp"

  NEWIP=$(sed -n "2,1p" NEWSPEED.tmp | awk -F, '{print $1}')
  if [[ -z "${NEWIP}" ]]; then
      echo "  CloudflareST 测速结果 IP 数量为 0，跳过下面步骤..."
      exit 0
  fi
  NEWSPEED=$(cat NEWSPEED.tmp |awk -F',' 'NR==2 {print $6}')
  echo $NEWIP >> result_archive.txt
  notify_tg "  优选成功，准备更新$NEWIP@$NEWSPEED to $NAME"
  DDNS_RESULT=$(timeout 20s curl -s \
      -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${DNS_RECORDS_ID}" \
      -H "X-Auth-Email: ${EMAIL}" \
      -H "X-Auth-Key: ${KEY}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"${TYPE}\",\"name\":\"${NAME}\",\"content\":\"${NEWIP}\",\"ttl\":${TTL},\"proxied\":${PROXIED}}" )
  if [ $? == 124 ]; then
    echo '  DDNS请求超时,请检查网络是否重启完成并是否能够访问api.cloudflare.com'
    exit 1
  fi

  IS_SUCCESS=$(echo "$DDNS_RESULT" | jq -r ".success")
  if [[ $IS_SUCCESS = "true" ]]; then
    notify_tg "  DDNS更新成功"
  else
    notify_tg "  DDNS更新失败请检查:$DDNS_RESULT"
    exit 1
  fi
  
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
  #cd "${FOLDER}"
  test_current
  if (( $(echo "$CURRENTSPEED < $TARGETSPEED" | bc -l)  )); then
    notify_tg "  当前车速 $CURRENTIP @ $CURRENTSPEED MB/s < 目标车速 $TARGETSPEED MB/s, 准备测速"
    test_and_update
  else
    MESSAGE="  当前车速 $CURRENTIP @ $CURRENTSPEED > 目标车速 $TARGETSPEED, 跳过测速"
    if [ $NOTIFY_TG_ABORT = 1 ]; then
      notify_tg "$MESSAGE"
    else
      echo "$MESSAGE"
    fi

  fi
} 

main


