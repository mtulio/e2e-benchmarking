#!/usr/bin/env bash

source ../../utils/common.sh
bo_path="/tmp/benchmark-operator"

set -x

# Removing benchmark-operator namespace, if it exists
oc delete namespace benchmark-operator --ignore-not-found

trap "rm -rf ${bo_path}" EXIT
_es=${ES_SERVER:-https://search-perfscale-dev-chmf5l4sh66lvxbnadi4bznl3a.us-west-2.es.amazonaws.com:443}
latency_th=${LATENCY_TH:-10000000}
index=ripsaw-fio-results
curl_body='{"_source": false, "aggs": {"max-fsync-lat-99th": {"max": {"field": "fio.sync.lat_ns.percentile.99.000000"}}}}'

if [ ! -z ${2} ]; then
  export KUBECONFIG=${2}
fi
openshift_login

cloud_name=$1
if [ "$cloud_name" == "" ]; then
  cloud_name="test_cloud"
fi

echo "Starting test for cloud: $cloud_name"

rm -rf ${bo_path}

oc create ns benchmark-operator
oc create ns backpack

git clone http://github.com/cloud-bulldozer/benchmark-operator ${bo_path} --depth 1
(cd ${bo_path} && make deploy)
kubectl apply -f ${bo_path}/resources/backpack_role.yaml
oc wait --for=condition=available "deployment/benchmark-controller-manager" -n benchmark-operator --timeout=300s

oc adm policy add-scc-to-user -n benchmark-operator privileged -z benchmark-operator
oc adm policy add-scc-to-user -n benchmark-operator privileged -z backpack-view

test_name="node-cpu"
cat << EOF | oc create -n benchmark-operator -f -
apiVersion: ripsaw.cloudbulldozer.io/v1alpha1
kind: Benchmark
metadata:
  name: ${test_name}
  namespace: benchmark-operator
spec:
  elasticsearch:
    url: ${_es}
  clustername: ${cloud_name}
  test_user: ${cloud_name}-ci
  metadata:
    collection: true
    serviceaccount: backpack-view
    privileged: true
  workload:
    name: sysbench
    args:
      enabled: true
      tests:
      - name: cpu
        parameters:
          cpu-max-prime: 2000
          time: 30
          threads: 2
      - name: cpu
        parameters:
          cpu-max-prime: 10000
          time: 30
          threads: 2
      - name: cpu
        parameters:
          cpu-max-prime: 20000
          time: 30
          threads: 2
EOF

# Get the uuid of newly created etcd-fio benchmark.
long_uuid=$(get_uuid 30)
if [ $? -ne 0 ]; 
then 
  exit 1
fi

uuid=${long_uuid:0:8}

# Checks the presence of etcd-fio pod. Should exit if pod is not available.
etcd_pod=$(get_pod "app=sysbench-$uuid" 300)
if [ $? -ne 0 ];
then
  echo "exit 1"
fi

check_pod_ready_state $etcd_pod 150s
if [ $? -ne 0 ];
then
  "Pod wasn't able to move into Running state! Exiting...."
  echo "exit 1"
fi

wk_state=1
for i in {1..60}; do
  if [[ $(oc get benchmark -n benchmark-operator ${test_name} -o jsonpath='{.status.complete}') == true ]]; then
    echo "Workload done"
    wk_state=$?
    uuid=$(oc get benchmark -n benchmark-operator ${test_name} -o jsonpath="{.status.uuid}")
    break
  fi
  sleep 30
done

if [ "$wk_state" == "1" ] ; then
  echo "Workload failed"
  exit 1
fi

#curl -s ${_es}/${index}/_search?q=uuid:${uuid} -H "Content-Type: application/json" -d "${curl_body}"
#fsync_lat=$(curl -s ${_es}/${index}/_search?q=uuid:${uuid} -H "Content-Type: application/json" -d "${curl_body}" | python -c 'import sys,json;print(int(json.loads(sys.stdin.read())["aggregations"]["max-fsync-lat-99th"]["value"]))')
#echo "Max 99th fsync latency observed: ${fsync_lat} ns"
#if [[ ${fsync_lat} -gt ${latency_th} ]]; then
#  echo "Latency greater than configured threshold: ${latency_th} ns"
#  exit 1
#fi

## Gathering results

echo "#> Starting collecting results..."

RES_PATH=${RESULTS_PATH:-'./.results'}
test -d ${RES_PATH} && rm -f ${RES_PATH}/*
mkdir -p ${RES_PATH}

oc -n benchmark-operator get pods -o json > ${RES_PATH}/pods.json

POD_NAME=$(jq -r '.items[] | select(.metadata.name | contains("sysbench-")) | .metadata.name' ${RES_PATH}/pods.json)
NODE_NAME=$(jq -r '.items[] | select(.metadata.name | contains("sysbench-")) | .spec.nodeName' ${RES_PATH}/pods.json)

oc -n benchmark-operator get all -o wide > ${RES_PATH}/ns-benchmark-operator-objects.txt
oc -n benchmark-operator get benchmark >> ${RES_PATH}/ns-benchmark-operator-objects.txt
oc -n benchmark-operator logs pod/${POD_NAME} > ${RES_PATH}/sysbench.txt

oc debug node/${NODE_NAME} -- chroot /host /bin/bash -c \
  'echo ">> [$(hostname)] [$(date)]"; uptime; cat /proc/cpuinfo; cat /proc/meminfo' > ${RES_PATH}/node_info.txt

exit 0
