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
  source cfst_ddns.conf
}

CURRENTIP=0.0.0.0
CURRENTSPEED=0

notify_tg()
{
  echo "$1"
  if [[ $NOTIFY_TG -eq 1 ]]; then
    res=$(timeout 20s curl -s -X POST $TG_URL \
            -d chat_id=${TG_USER_ID} \
            -d parse_mode=${TG_MODE} \
            -d text="$1")

    if [ $? == 124 ]; then
      echo '  TG_api请求超时,请检查网络是否重启完成并是否能够访问TG'          
      exit 1
    fi
    
    resSuccess=$(echo "$res" | jq -r ".ok")
    if [[ $resSuccess = "true" ]]; then
      echo "  TG推送成功"
    else
      echo "  TG推送失败，请检查TG机器人token和ID"
    fi
  fi
}


test_current()
{
  
  CURRENTIP=$(nslookup $NAME 1.1.1.1 | \
              grep "Address: "| awk -F': ' '{ print $2 }')

  echo "  Speed Testing current $CURRENTIP"

  ./CloudflareST \
     -url $TESTURL \
     -o CURRENTSPEED.tmp \
     -ip $CURRENTIP \
     > /dev/null 2>&1

  CURRENTSPEED=$(cat CURRENTSPEED.tmp |awk -F',' 'NR==2 {print $6}')

  echo "  Current Speed: $CURRENTSPEED MB/s" 
}

test_and_update() 
{

  # 这里可以自己添加、修改 CloudflareST 的运行参数
  ./CloudflareST \
      -url $TESTURL \
      -t 1 -n 500 -p 1 -tp 443 \
      -dn $TARGETNUMBEROFIP \
      -sl $TARGETSPEED \
      -tl 250 -tll 40 \
      -o "NEWSPEED.tmp"

  CONTENT=$(sed -n "2,1p" NEWSPEED.tmp | awk -F, '{print $1}')
  if [[ -z "${CONTENT}" ]]; then
      echo "  CloudflareST 测速结果 IP 数量为 0，跳过下面步骤..."
      exit 0
  fi
  NEWSPEED=$(cat NEWSPEED.tmp |awk -F',' 'NR==2 {print $6}')
  echo $NEWSPEED >> result_archive.txt
  notify_tg "  优选成功，准备更新$CONTENT@$NEWSPEED to $NAME"
  DDNS_RESULT=$(timeout 20s curl -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${DNS_RECORDS_ID}" \
      -H "X-Auth-Email: ${EMAIL}" \
      -H "X-Auth-Key: ${KEY}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"${TYPE}\",\"name\":\"${NAME}\",\"content\":\"${CONTENT}\",\"ttl\":${TTL},\"proxied\":${PROXIED}}" )
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
      echo "  TCP Proxy Mode = $last_tcp_mode"
  fi
  date "+<<<< Goodbye %m/%d %H:%M <<<<"
}

main(){
  date "+>>>> Hello   %m/%d %H:%M >>>>"
  trap handle_exit EXIT HUP INT TERM
  last_tcp_mode=$(uci get "passwall.@global[0].tcp_proxy_mode")
  echo "  TCP Proxy Mode = $last_tcp_mode"
    
  if [ "$last_tcp_mode" != "disable" ]; then
    uci set "passwall.@global[0].tcp_proxy_mode"='disable'
    uci commit
    echo "  TCP Proxy Mode = Disabled"
  fi

  read_config
  #cd "${FOLDER}"
  test_current
  if [[ $(echo "$CURRENTSPEED - $TARGETSPEED" | bc) < 0  ]]; then
    notify_tg "  Current $CURRENTIP @ $CURRENTSPEED MB/s < Target $TARGETSPEED MB/s, selecting new IP"
    test_and_update
  else
    echo "  Current $CURRENTIP @ $CURRENTSPEED > Target $TARGETSPEED, abort"
  fi
} 

main


