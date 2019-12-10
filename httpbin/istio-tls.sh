#! /bin/zsh

case "$1" in
  apply)
    # Create CA (example.com)
    openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -subj '/O=example Inc./CN=example.com' -keyout example.com.key -out example.com.crt

    # Create httpbin.example.com cert and key
    openssl req -out httpbin.example.com.csr -newkey rsa:2048 -nodes -keyout httpbin.example.com.key -subj "/CN=httpbin.example.com/O=httpbin organization"
    openssl x509 -req -days 365 -CA example.com.crt -CAkey example.com.key -set_serial 0 -in httpbin.example.com.csr -out httpbin.example.com.crt

    # Create the secret for the ingressgateway to be able to mount the certs
    kubectl create -n istio-system secret tls istio-ingressgateway-certs --key httpbin.example.com.key --cert httpbin.example.com.crt

    # Define final text
    read -r FINAL_TEXT <<EOF
You can either use curl or modify your /etc/hosts file to include the istio ingressgateway IP that resolves to httpbin.example.com
curl -v -HHost:httpbin.example.com --resolve httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST --cacert example.com.crt https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418
EOF
    ;;
  delete)
    # Delete certs, keys, CSR and secret
    rm *.(crt|key|csr)
    kubectl delete -n istio-system secret istio-ingressgateway-certs
    # Define final text
    read -r FINAL_TEXT << EOF
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
  name: httpbin
  namespace: istio-stuff
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  labels:
    app: httpbin
  namespace: istio-stuff
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: istio-stuff
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
      - image: docker.io/kennethreitz/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 80
EOF

# Create a gateway
kubectl ${1} -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: httpbin-gateway
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
    - "httpbin.example.com"
EOF

# Create a VirtualService
kubectl ${1} -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: httpbin
  namespace: istio-stuff
spec:
  hosts:
  - "httpbin.example.com"
  gateways:
  - httpbin-gateway
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        port:
          number: 8000
        host: httpbin
EOF


# Final steps

echo "$FINAL_TEXT"
