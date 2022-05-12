#!/bin/bash

set -e

if [ -n "$DEBUG" ] ; then
    set -x
fi

help() {
    echo "usage:"
    echo "TOKEN=<token> genprojects.sh create --host <rancher host> --cluster <cluster ID> [--scale <scale>] [--create-namespaces] [--kubectl]"
    echo "TOKEN=<token> genprojects.sh delete --host <rancher host> --cluster <cluster ID>"
    exit
}

COMMAND=$1
if [ "$COMMAND" != "create" -a "$COMMAND" != "delete" ] ; then
    help
fi
shift

while (( "$#" )) ; do
    case $1 in
        --host)
            HOST=$2
            shift
            shift
            ;;
        --cluster)
            CLUSTER=$2
            shift
            shift
            ;;
        --scale)
            SCALE=$2
            shift
            shift
            ;;
        --create-namespaces)
            CREATENS=y
            shift
            ;;
        --kubectl)
            KUBECTL=y
            shift
            ;;
        *)
            help
            ;;
    esac
done

SCALE=${SCALE:-10}
CREATENS=${CREATENS:-n}
KUBECTL=${KUBECTL:-n}

labelKey=scalingmock
labelObj='"'$labelKey'":"true"'
labelSelector="${labelKey}=true"

[ -z "$TOKEN" ] && help
[ -z "$HOST" ] && help
[ -z "$CLUSTER" ] && help

delete() {
    namespaces=$(curl $HOST/k8s/clusters/$CLUSTER/v1/namespaces?labelSelector=$labelSelector \
        -u $TOKEN -H 'Accept: application/json' -H 'Content-Type: application/json' | \
        jq -r .data[].id)
    echo "deleting namespaces $namespaces"
    for n in $namespaces ; do
        curl -s -u $TOKEN -X DELETE $HOST/k8s/clusters/$CLUSTER/v1/namespaces/$n
    done
    projects=$(curl $HOST/v3/projects \
        -u $TOKEN -H 'Accept: application/json' | \
        jq -r '.data[] | select(.labels | contains({'$labelObj'})) | .id')
    echo "deleting projects $projects"
    for p in $projects ; do
        curl -s -u $TOKEN $HOST/v3/projects/$p -X DELETE
    done
}

create() {
    for i in `seq $SCALE` ; do
        resp=$(curl -i -k $HOST/v3/projects \
            -s -u $TOKEN -X POST \
            -H 'Accept: application/json' -H 'Content-Type: application/json' \
            -d \
            '{
                "clusterId": "'$CLUSTER'",
                "name": "p'$i'",
                "labels": {'$labelObj'}
            }')
        echo "$resp" | head -1
        projectID=$(echo "$resp" | awk 'f;/^\r$/{f=1}' | jq -r .id )
        if [ "$projectID" == "null" ] ; then
            echo "problem creating project $i"
            exit 1
        fi
        echo "$projectID"
        if [ "$CREATENS" == y ] ; then
            resp=$(curl -i -k $HOST/k8s/clusters/$CLUSTER/v1/namespaces \
                -s -u $TOKEN -X POST \
                -H 'Accept: application/json' -H 'Content-Type: application/json' \
                -d \
                '{
                    "type": "namespace",
                    "metadata": {
                        "annotations": {
                            "field.cattle.io/projectId": "'$projectID'"
                        },
                        "labels": {
                            "field.cattle.io/projectId": "'$(echo $projectID | cut -d ':' -f 2)'",
                            '$labelObj'
                        },
                        "name": "n'$i'"
                    }
                }')
            echo "$resp" | head -1
            echo "$resp" | awk 'f;/^\r$/{f=1}' | jq -r .id
        fi
    done
}

kubectl_create() {
    for i in `seq $SCALE` ; do
        cat <<EOF | sed -e "s/NAME/p$i/" -e "s/CLUSTER/$CLUSTER/" | kubectl apply -f -
apiVersion: management.cattle.io/v3
kind: Project
metadata:
  labels:
    scalingmock: "true"
  name: NAME
  namespace: CLUSTER
spec:
  clusterName: CLUSTER
EOF
    done
}

if [ "$COMMAND" == "delete" ]; then
    delete
else
    if [ "$KUBECTL" == y ] ; then
        kubectl_create
    else
        create
    fi
fi
