#!/usr/bin/env bash

set -eu
set -o pipefail


source "${BASH_SOURCE[0]%/*}"/lib/testing.sh


cid_es="$(container_id elasticsearch)"
cid_mb="$(container_id metricbeat)"

ip_es="$(service_ip elasticsearch)"
ip_mb="$(service_ip metricbeat)"

grouplog 'Wait for readiness of Elasticsearch'
poll_ready "$cid_es" 'http://elasticsearch:9200/' --resolve "elasticsearch:9200:${ip_es}" -u 'elastic:testpasswd'
endgroup

grouplog 'Wait for readiness of Metricbeat'
poll_ready "$cid_mb" 'http://metricbeat:5066/?pretty' --resolve "metricbeat:5066:${ip_mb}"
endgroup

# We expect to find monitoring entries for the 'elasticsearch' Compose service
# using the following query:
#
#   agent.type:"metricbeat"
#   AND event.module:"docker"
#   AND event.dataset:"docker.container"
#   AND container.name:"docker-elk-elasticsearch-1"
#
log 'Searching a document generated by Metricbeat'

declare response
declare -i count

declare -i was_retried=0

# retry for max 60s (30*2s)
for _ in $(seq 1 30); do
	response="$(curl 'http://elasticsearch:9200/metricbeat-*/_search?q=agent.type:%22metricbeat%22%20AND%20event.module:%22docker%22%20AND%20event.dataset:%22docker.container%22%20AND%20container.name:%22docker-elk-elasticsearch-1%22&size=1&pretty' -s --resolve "elasticsearch:9200:${ip_es}" -u elastic:testpasswd)"

	set +u  # prevent "unbound variable" if assigned value is not an integer
	count="$(jq -rn --argjson data "${response}" '$data.hits.total.value')"
	set -u

	if (( count > 0 )); then
		break
	fi

	was_retried=1
	echo -n 'x' >&2
	sleep 2
done
if ((was_retried)); then
	# flush stderr, important in non-interactive environments (CI)
	echo >&2
fi

echo "$response"
# Metricbeat buffers metrics until Elasticsearch becomes ready, so we tolerate
# multiple results
if (( count == 0 )); then
	echo 'Expected at least 1 document'
	exit 1
fi
