#! /bin/zsh

case "$1" in
  apply)
    # Create CA (ozrlz.com)
    openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -subj '/O=Ozrlz Inc./CN=ozrlz.com' -keyout ozrlz.com.key -out ozrlz.com.crt

    # Create flask.ozrlz.com cert and key
    openssl req -out flask.ozrlz.com.csr -newkey rsa:2048 -nodes -keyout flask.ozrlz.com.key -subj "/CN=flask.ozrlz.com/O=Flask organization"
    openssl x509 -req -days 365 -CA ozrlz.com.crt -CAkey ozrlz.com.key -set_serial 0 -in flask.ozrlz.com.csr -out flask.ozrlz.com.crt

    # Create the secret for the ingressgateway to be able to mount the certs
    kubectl create -n istio-system secret tls istio-ingressgateway-certs --key flask.ozrlz.com.key --cert flask.ozrlz.com.crt

    # Define final text
    read -r -d '' FINAL_TEXT <<EOF
You can either use curl or modify your /etc/hosts file to include the istio ingressgateway IP that resolves to flask.ozrlz.com
curl -v -HHost:flask.ozrlz.com --resolve flask.ozrlz.com:$SECURE_INGRESS_PORT:$INGRESS_HOST --cacert ozrlz.com.crt https://flask.ozrlz.com:$SECURE_INGRESS_PORT/
EOF
    ;;
  delete)
    # Delete certs, keys, CSR and secret
    rm *.(crt|key|csr)
    kubectl delete -n istio-system secret istio-ingressgateway-certs
    # Define final text
    read -r -d '' FINAL_TEXT << EOF
The files and kubernetes resources were deleted
Run apply again to create those again
EOF
    ;;
  *)
    echo "Usage: $0 apply|delete"
    exit 1
esac

# Create a new namespace, label it and create httpbin resources
kubectl $1 -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: istio-stuff
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flask
  namespace: istio-stuff
---
apiVersion: v1
kind: Service
metadata:
  name: flask
  labels:
    app: flask
  namespace: istio-stuff
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 5000
  selector:
    app: flask
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask
  namespace: istio-stuff
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flask
      version: v1
  template:
    metadata:
      labels:
        app: flask
        version: v1
    spec:
      serviceAccountName: flask
      containers:
      - image: ozrlz/flask-client:k8s
        imagePullPolicy: IfNotPresent
        name: flask
        ports:
        - containerPort: 5000
EOF

# Create a gateway
kubectl ${1} -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: flask-gateway
  namespace: istio-stuff
spec:
  selector:
    istio: ingressgateway # use istio default ingress gateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      serverCertificate: /etc/istio/ingressgateway-certs/tls.crt
      privateKey: /etc/istio/ingressgateway-certs/tls.key
    hosts:
    - "flask.ozrlz.com"
EOF

# Create a VirtualService
kubectl ${1} -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: flask
  namespace: istio-stuff
spec:
  hosts:
  - "flask.ozrlz.com"
  gateways:
  - flask-gateway
  http:
  - match:
    - uri:
        exact: /
    route:
    - destination:
        port:
          number: 8000
        host: flask
EOF


# Final steps

echo "$FINAL_TEXT"
