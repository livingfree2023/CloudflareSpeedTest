#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
# --------------------------------------------------------------
#	项目: CloudflareSpeedTest 自动更新域名解析记录
#	版本: 1.0.4
#	作者: XIU2
#	项目: https://github.com/XIU2/CloudflareSpeedTest
# --------------------------------------------------------------

_READ() {
  source cfst_ddns.conf
}

CURRENTIP=0.0.0.0
CURRENTSPEED=0

notify_tg(){
  echo $1
  if [[ $NOTIFY_TG -eq 1 ]]; then
    res=$(timeout 20s curl -s -X POST $TG_URL \
            -d chat_id=${TG_USER_ID} \
            -d parse_mode=${TG_MODE} \
            -d text="$1")

    if [ $? == 124 ];then
      echo 'TG_api请求超时,请检查网络是否重启完成并是否能够访问TG'          
      exit 1
    fi
    resSuccess=$(echo "$res" | jq -r ".ok")
    if [[ $resSuccess = "true" ]]; then
      echo "TG推送成功";
    else
      echo "TG推送失败，请检查TG机器人token和ID";
    fi
  fi
}


_TESTCURRENT()
{
  
  CURRENTIP=$(nslookup $NAME 1.1.1.1 | \
              grep "Address: "| awk -F': ' '{ print $2 }')

  echo "*** Testing current IP ($CURRENTIP) "

  ./CloudflareST \
     -url $TESTURL \
     -o CURRENTSPEED.tmp \
     -ip $CURRENTIP \
     > /dev/null 2>&1

  CURRENTSPEED=$(cat CURRENTSPEED.tmp |awk -F',' 'NR==2 {print $6}')

  echo "*** Current Speed: $CURRENTSPEED MB/s" #|nali
}




_UPDATE() {
  date "+_UPDATE %m%d%H%M"
    # 这里可以自己添加、修改 CloudflareST 的运行参数

  ./CloudflareST \
      -url $TESTURL \
      -t 1 -n 500 -p 1 -tp 443 \
      -dn $TARGETNUMBEROFIP \
      -sl $TARGETSPEED \
      -tl 250 -tll 40 \
      -o "result_ddns.txt"


    # 判断结果文件是否存在，如果不存在说明结果为 0
  #	[[ ! -e "result_ddns.txt" ]] && echo "CloudflareST 测速结果 IP 数量为 0，跳过下面步骤..." && exit 0
    # # 如果需要 "找不到满足条件的 IP 就一直循环测速下去"，那么可以将下面的两个 exit 0 改为 _UPDATE 即可
    # [[ ! -e "result_ddns.txt" ]] && echo "CloudflareST 测速结果 IP 数量为 0，重试..." && _UPDATE #exit 0

    # # 下面这行代码是 "找不到满足条件的 IP 就一直循环测速下去" 才需要的代码
    # # 考虑到当指定了下载速度下限，但一个满足全部条件的 IP 都没找到时，CloudflareST 就会输出所有 IP 结果
    # # 因此当你指定 -sl 参数时，需要移除下面这段代码开头的 # 井号注释符，来做文件行数判断（比如下载测速数量：10 个，那么下面的值就设在为 11）
    # [[ $(cat result_ddns.txt|wc -l) > $((numberOfIP+1)) ]] && echo "CloudflareST 测速结果没有找到一个完全满足条件的 IP，重新测速..." && _UPDATE

    CONTENT=$(sed -n "2,1p" result_ddns.txt | awk -F, '{print $1}')
    if [[ -z "${CONTENT}" ]]; then
        echo "CloudflareST 测速结果 IP 数量为 0，跳过下面步骤..."
        exit 0
    fi
    NEWSPEED=$(sed -n "2,1p" result_ddns.txt |awk -F',' 'NR==2 {print $6}')
    #echo "*** 优选成功，准备更新$CONTENT to $NAME"
    notify_tg "优选成功，准备更新$CONTENT@$NEWSPEED to $NAME"
    curl -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${DNS_RECORDS_ID}" \
        -H "X-Auth-Email: ${EMAIL}" \
        -H "X-Auth-Key: ${KEY}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${TYPE}\",\"name\":\"${NAME}\",\"content\":\"${CONTENT}\",\"ttl\":${TTL},\"proxied\":${PROXIED}}"
}



handle_exit(){
  
  if [ "$current_tcp_mode" != "disable" ]; then
      uci set "passwall.@global[0].tcp_proxy_mode"=$current_tcp_mode
    uci commit
      echo "TCP Proxy Mode = $current_tcp_mode"
  fi
  echo "*** Goodbye"
}

main(){
  trap handle_exit EXIT HUP INT TERM
  current_tcp_mode=$(uci get "passwall.@global[0].tcp_proxy_mode")
  echo "TCP Proxy Mode = $current_tcp_mode"
    
  if [ "$current_tcp_mode" != "disable" ]; then
    uci set "passwall.@global[0].tcp_proxy_mode"='disable'
    uci commit
    echo "TCP Proxy Mode = Disabled"
  fi

  _READ
  cd "${FOLDER}"
  _TESTCURRENT
  if [[ $(echo "$CURRENTSPEED - $TARGETSPEED" | bc) < 0  ]]; then
    #echo "Current speed ($CURRENTSPEED) less than target speed ($TARGETSPEED), RUNNING tests"
    notify_tg "Current $CURRENTIP@$CURRENTSPEED MB/s < target $TARGETSPEED MB/s, selecting new IP"
    _UPDATE
  else
    echo "Current speed $CURRENTSPEED > target speed $TARGETSPEED, SKIPPING tests and notify"
    #notify_tg "Current IP $CURRENTIP@$CURRENTSPEED MB/s greater than target $TARGETSPEED MB/s, SKIPPING tests"
  fi
} 

main


