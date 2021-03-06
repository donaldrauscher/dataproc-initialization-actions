#!/bin/bash
#    Copyright 2015 Google, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
set -x -e

# Variables for running this script
ROLE=$(/usr/share/google/get_metadata_value attributes/dataproc-role)
HOSTNAME=$(hostname -s)
PRESTO_MASTER_FQDN=$(/usr/share/google/get_metadata_value attributes/dataproc-master)
WORKER_COUNT=$(/usr/share/google/get_metadata_value attributes/dataproc-worker-count)
CONNECTOR_JAR=$(find /usr/lib/hadoop/lib -name 'gcs-connector-*.jar')
PRESTO_VERSION="0.177"
HTTP_PORT="8080"

# Download and unpack Presto server
wget https://repo1.maven.org/maven2/com/facebook/presto/presto-server/${PRESTO_VERSION}/presto-server-${PRESTO_VERSION}.tar.gz
tar -zxvf presto-server-${PRESTO_VERSION}.tar.gz
mkdir /var/presto
mkdir /var/presto/data

# Copy required Jars
cp ${CONNECTOR_JAR} presto-server-${PRESTO_VERSION}/plugin/hive-hadoop2

# Configure Presto
mkdir presto-server-${PRESTO_VERSION}/etc
mkdir presto-server-${PRESTO_VERSION}/etc/catalog

cat > presto-server-${PRESTO_VERSION}/etc/node.properties <<EOF
node.environment=production
node.id=$(uuidgen)
node.data-dir=/var/presto/data
EOF

METASTORE_URI=$(bdconfig get_property_value \
  --configuration_file /etc/hive/conf/hive-site.xml \
  --name hive.metastore.uris 2>/dev/null)

cat > presto-server-${PRESTO_VERSION}/etc/catalog/hive.properties <<EOF
connector.name=hive-hadoop2
hive.metastore.uri=${METASTORE_URI}
EOF

# Compute memory settings based on Spark's settings.
# We use "tail -n 1" since overrides are applied just by order of appearance.
SPARK_EXECUTOR_MB=$(grep spark.executor.memory /etc/spark/conf/spark-defaults.conf | tail -n 1 | sed 's/.*[[:space:]=]\+\([[:digit:]]\+\).*/\1/')
SPARK_EXECUTOR_CORES=$(grep spark.executor.cores /etc/spark/conf/spark-defaults.conf | tail -n 1 | sed 's/.*[[:space:]=]\+\([[:digit:]]\+\).*/\1/')
SPARK_EXECUTOR_OVERHEAD_MB=$(grep spark.yarn.executor.memoryOverhead /etc/spark/conf/spark-defaults.conf | tail -n 1 | sed 's/.*[[:space:]=]\+\([[:digit:]]\+\).*/\1/')
if [[ -z "${SPARK_EXECUTOR_OVERHEAD_MB}" ]]; then
  # When spark.yarn.executor.memoryOverhead couldnt't be found in
  # spark-defaults.conf, use Spark default properties:
  # executorMemory * 0.10, with minimum of 384
  MIN_EXECUTOR_OVERHEAD=384
  SPARK_EXECUTOR_OVERHEAD_MB=$(( ${SPARK_EXECUTOR_MB} / 10 ))
  SPARK_EXECUTOR_OVERHEAD_MB=$(( ${SPARK_EXECUTOR_OVERHEAD_MB}>${MIN_EXECUTOR_OVERHEAD}?${SPARK_EXECUTOR_OVERHEAD_MB}:${MIN_EXECUTOR_OVERHEAD} ))
fi
SPARK_EXECUTOR_COUNT=$(( $(nproc) / ${SPARK_EXECUTOR_CORES} ))

# Add up overhead and allocated executor MB for container size.
SPARK_CONTAINER_MB=$(( ${SPARK_EXECUTOR_MB} + ${SPARK_EXECUTOR_OVERHEAD_MB} ))
PRESTO_JVM_MB=$(( ${SPARK_CONTAINER_MB} * ${SPARK_EXECUTOR_COUNT} ))

# Give query.max-memorr-per-node 60% of Xmx; this more-or-less assumes a
# single-tenant use case rather than trying to allow many concurrent queries
# against a shared cluster.
# Subtract out SPARK_EXECUTOR_OVERHEAD_MB in both the query MB and reserved
# system MB as a crude approximation of other unaccounted overhead that we need
# to leave betweenused bytes and Xmx bytes. Rounding down by integer division
# here also effectively places round-down bytes in the "general" pool.
PRESTO_QUERY_NODE_MB=$(( ${PRESTO_JVM_MB} * 6 / 10 - ${SPARK_EXECUTOR_OVERHEAD_MB} ))
PRESTO_RESERVED_SYSTEM_MB=$(( ${PRESTO_JVM_MB} * 4 / 10 - ${SPARK_EXECUTOR_OVERHEAD_MB} ))

cat > presto-server-${PRESTO_VERSION}/etc/jvm.config <<EOF
-server
-Xmx${PRESTO_JVM_MB}m
-Xmn512m
-XX:+UseConcMarkSweepGC
-XX:+ExplicitGCInvokesConcurrent
-XX:ReservedCodeCacheSize=150M
-XX:+ExplicitGCInvokesConcurrent
-XX:+CMSClassUnloadingEnabled
-XX:+AggressiveOpts
-XX:+HeapDumpOnOutOfMemoryError
-XX:OnOutOfMemoryError=kill -9 %p
-Dhive.config.resources=/etc/hadoop/conf/core-site.xml,/etc/hadoop/conf/hdfs-site.xml
-Djava.library.path=/usr/lib/hadoop/lib/native/:/usr/lib/
EOF

# Start coordinator only on main Master
if [[ "${HOSTNAME}" == "${PRESTO_MASTER_FQDN}" ]]; then
  # Configure master properties
  if [[ $WORKER_COUNT == 0 ]]; then
    # master on single-node is also worker
    include_coordinator='true'
  else
    include_coordinator='false'
  fi
  cat > presto-server-${PRESTO_VERSION}/etc/config.properties <<EOF
coordinator=true
node-scheduler.include-coordinator=${include_coordinator}
http-server.http.port=${HTTP_PORT}
query.max-memory=999TB
query.max-memory-per-node=${PRESTO_QUERY_NODE_MB}MB
resources.reserved-system-memory=${PRESTO_RESERVED_SYSTEM_MB}MB
discovery-server.enabled=true
discovery.uri=http://${PRESTO_MASTER_FQDN}:${HTTP_PORT}
EOF

	# Install cli
	$(wget https://repo1.maven.org/maven2/com/facebook/presto/presto-cli/${PRESTO_VERSION}/presto-cli-${PRESTO_VERSION}-executable.jar -O /usr/bin/presto)
	$(chmod a+x /usr/bin/presto)
  # Start presto coordinator
  presto-server-${PRESTO_VERSION}/bin/launcher start
fi

if [[ "${ROLE}" == 'Worker' ]]; then
	cat > presto-server-${PRESTO_VERSION}/etc/config.properties <<EOF
coordinator=false
http-server.http.port=${HTTP_PORT}
query.max-memory=999TB
query.max-memory-per-node=${PRESTO_QUERY_NODE_MB}MB
resources.reserved-system-memory=${PRESTO_RESERVED_SYSTEM_MB}MB
discovery.uri=http://${PRESTO_MASTER_FQDN}:${HTTP_PORT}
EOF
  # Start presto worker
  presto-server-${PRESTO_VERSION}/bin/launcher start
fi

