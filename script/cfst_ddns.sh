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
	[[ ! -e "cfst_ddns.conf" ]] && echo -e "[错误] 配置文件不存在 [cfst_ddns.conf] !" && exit 1
	CONFIG=$(cat "cfst_ddns.conf")
	FOLDER=$(echo "${CONFIG}"|grep 'FOLDER='|awk -F '=' '{print $NF}')
	[[ -z "${FOLDER}" ]] && echo -e "[错误] 缺少配置项 [FOLDER] !" && exit 1
	ZONE_ID=$(echo "${CONFIG}"|grep 'ZONE_ID='|awk -F '=' '{print $NF}')
	[[ -z "${ZONE_ID}" ]] && echo -e "[错误] 缺少配置项 [ZONE_ID] !" && exit 1
	DNS_RECORDS_ID=$(echo "${CONFIG}"|grep 'DNS_RECORDS_ID='|awk -F '=' '{print $NF}')
	[[ -z "${DNS_RECORDS_ID}" ]] && echo -e "[错误] 缺少配置项 [DNS_RECORDS_ID] !" && exit 1
	EMAIL=$(echo "${CONFIG}"|grep 'EMAIL='|awk -F '=' '{print $NF}')
	[[ -z "${EMAIL}" ]] && echo -e "[错误] 缺少配置项 [EMAIL] !" && exit 1
	KEY=$(echo "${CONFIG}"|grep 'KEY='|awk -F '=' '{print $NF}')
	[[ -z "${KEY}" ]] && echo -e "[错误] 缺少配置项 [KEY] !" && exit 1
	TYPE=$(echo "${CONFIG}"|grep 'TYPE='|awk -F '=' '{print $NF}')
	[[ -z "${TYPE}" ]] && echo -e "[错误] 缺少配置项 [TYPE] !" && exit 1
	NAME=$(echo "${CONFIG}"|grep 'NAME='|awk -F '=' '{print $NF}')
	[[ -z "${NAME}" ]] && echo -e "[错误] 缺少配置项 [NAME] !" && exit 1
	TTL=$(echo "${CONFIG}"|grep 'TTL='|awk -F '=' '{print $NF}')
	[[ -z "${TTL}" ]] && echo -e "[错误] 缺少配置项 [TTL] !" && exit 1
	PROXIED=$(echo "${CONFIG}"|grep 'PROXIED='|awk -F '=' '{print $NF}')
	[[ -z "${PROXIED}" ]] && echo -e "[错误] 缺少配置项 [PROXIED] !" && exit 1
	TESTURL=$(echo "${CONFIG}"|grep 'TESTURL='|awk -F '=' '{print $NF}')
	[[ -z "${TESTURL}" ]] && echo -e "[错误] 缺少配置项 [TESTURL] !" && exit 1
	TARGETNUMBEROFIP=$(echo "${CONFIG}"|grep 'TARGETNUMBEROFIP='|awk -F '=' '{print $NF}')
	[[ -z "${TARGETNUMBEROFIP}" ]] && echo -e "[错误] 缺少配置项 [TARGETNUMBEROFIP] !" && exit 1
	TARGETSPEED=$(echo "${CONFIG}"|grep 'TARGETSPEED='|awk -F '=' '{print $NF}')
	[[ -z "${TARGETSPEED}" ]] && echo -e "[错误] 缺少配置项 [TARGETSPEED] !" && exit 1
}

CURRENTIP=0.0.0.0
CURRENTSPEED=0


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
#-----------------
  	# 如果需要 "找不到满足条件的 IP 就一直循环测速下去"，那么可以将下面的两个 exit 0 改为 _UPDATE 即可
	[[ ! -e "result_ddns.txt" ]] && echo "CloudflareST 测速结果 IP 数量为 0，重试..." && _UPDATE #exit 0

	# 下面这行代码是 "找不到满足条件的 IP 就一直循环测速下去" 才需要的代码
	# 考虑到当指定了下载速度下限，但一个满足全部条件的 IP 都没找到时，CloudflareST 就会输出所有 IP 结果
	# 因此当你指定 -sl 参数时，需要移除下面这段代码开头的 # 井号注释符，来做文件行数判断（比如下载测速数量：10 个，那么下面的值就设在为 11）
	[[ $(cat result_ddns.txt|wc -l) > $((numberOfIP+1)) ]] && echo "CloudflareST 测速结果没有找到一个完全满足条件的 IP，重新测速..." && _UPDATE


#-----------------
	CONTENT=$(sed -n "2,1p" result_ddns.txt | awk -F, '{print $1}')
	if [[ -z "${CONTENT}" ]]; then
		echo "CloudflareST 测速结果 IP 数量为 0，跳过下面步骤..."
		exit 0
	fi
	echo "*** 看上去一切正常，准备更新$CONTENT to $NAME"
	curl -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${DNS_RECORDS_ID}" \
		-H "X-Auth-Email: ${EMAIL}" \
		-H "X-Auth-Key: ${KEY}" \
		-H "Content-Type: application/json" \
		--data "{\"type\":\"${TYPE}\",\"name\":\"${NAME}\",\"content\":\"${CONTENT}\",\"ttl\":${TTL},\"proxied\":${PROXIED}}"
}



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
  echo "Current speed ($CURRENTSPEED) less than target speed ($TARGETSPEED), RUNNING tests"
  _UPDATE
else
  echo "Current speed ($CURRENTSPEED) greater than target speed ($TARGETSPEED), SKIPPING tests"
fi

if [ "$current_tcp_mode" != "disable" ]; then
  uci set "passwall.@global[0].tcp_proxy_mode"=$current_tcp_mode
  uci commit
  echo "TCP Proxy Mode = $current_tcp_mode"
fi

