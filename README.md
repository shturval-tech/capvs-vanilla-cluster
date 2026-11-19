# capvs-vanilla-cluster

Helm-чарт для создания workload-кластера Kubernetes через **чистый (vanilla)
Cluster API** и **CAPV** (Cluster API Provider vSphere).

Это не drop-in замена `capvs-cluster`: другие имена values, другой namespace
и API `v1beta2`. Чарт создаёт только стандартные объекты CAPI `v1beta2` и CAPV `v1beta2`.

## Что создаётся

- `Secret` с кредами vCenter (в namespace релиза) — опционально;
- `VSphereCluster`;
- `Cluster`;
- `KubeadmControlPlane`;
- `VSphereMachineTemplate` для control plane;
- для каждой worker-группы:
  - `MachineDeployment`;
  - `KubeadmConfigTemplate`;
  - `VSphereMachineTemplate`;
  - `MachineHealthCheck` (опционально).

`kube-vip` static pod добавляется в `KubeadmControlPlane`, только если
`kubeVip.enabled: true`.

## Чего чарт не делает

Cluster API не устанавливает «всё остальное». Чарт сознательно не создаёт:

- **CNI** (Cilium/Calico/Flannel) — без него узлы будут `NotReady`;
- **CSI** (vSphere CSI) и **CPI** (vSphere Cloud Provider);
- ingress, cert-manager, monitoring, logging;
- cluster-autoscaler;
- audit/encryption-at-rest (можно добавить через `kubeadm.*` и
  `controlPlane.extraFiles`).

Это не «недоделка», а граница ответственности: чарт создаёт кластер, а
платформенные сервисы ставятся отдельно.

## Требования

1. Management-кластер с установленными:
   - Cluster API core **>= 1.11** (контракт `v1beta2`);
   - CAPV **>= 1.16** (контракт `v1beta2`).

   На момент написания актуальны CAPI `v1.14` и CAPV `v1.17`; чарт
   использует их контракт `v1beta2`. Если в management-кластере только
   `v1beta1`, чарт не подойдёт.

2. В vCenter:
   - пользователь с правами на клонирование VM, чтение inventory, работа с
     network/datastore;
   - VM-шаблон с cloud-init, containerd, kubeadm и kubelet. Готовые шаблоны
     собираются [image-builder](https://github.com/kubernetes-sigs/image-builder);
     версии kubeadm/kubelet в шаблоне должны быть совместимы с
     `cluster.kubernetesVersion` (kubeadm не устанавливает kubelet);
   - datacenter, datastore, folder, resource pool, network.

3. Свободный IP/DNS для `kube-apiserver` (см. ниже).

4. Helm >= 3.14.

Проверка management-кластера:

```bash
kubectl api-resources | grep -E 'clusters.cluster.x-k8s.io|vsphereclusters'
kubectl get crd clusters.cluster.x-k8s.io \
  -o jsonpath='{.spec.versions[*].name}'
kubectl get crd vsphereclusters.infrastructure.cluster.x-k8s.io \
  -o jsonpath='{.spec.versions[*].name}'
```

В обоих списках должен быть `v1beta2`.

## Быстрый старт

Создайте `my-values.yaml` (пример — `values-test.yaml`):

```yaml
cluster:
  name: demo
  kubernetesVersion: "1.36.6"
  endpoint:
    host: 10.0.0.50          # ЗАМЕНИТЕ
    port: 6443
  podCIDR: 192.168.0.0/16
  serviceCIDR: 10.96.0.0/12

vsphere:
  server: vcenter.example.com
  thumbprint: "AA:BB:CC:..." # SHA-1 vCenter, иначе TLS не проверяется
  username: administrator@vsphere.local
  password: "CHANGE_ME"      # лучше — existingSecret
  datacenter: /Datacenter
  datastore: vsanDatastore
  folder: /Datacenter/vm/capi
  resourcePool: /Datacenter/host/Cluster/Resources
  template: ubuntu-2404-capi-template
  network:
    devices:
      - networkName: /Datacenter/network/VM Network
        dhcp4: true

controlPlane:
  replicas: 1

kubeVip:
  enabled: true
  interface: eth0

workerNodes:
  workers:
    replicas: 2
```

`10.0.0.50` — свободный VIP для kube-vip; control-plane и worker-узлы
получают адреса по DHCP. kube-vip поднимает VIP на единственном
control-plane узле, поэтому отдельный балансировщик не нужен.

Без kube-vip тоже можно: если DHCP выдаёт control-plane узлу фиксированный
адрес по резервации, оставьте `dhcp4: true` и укажите этот
зарезервированный IP в `cluster.endpoint.host`. Статические `ipAddrs`
в `VSphereMachineTemplate` CAPV `v1beta2` запрещает.

Установка:

```bash
helm upgrade --install demo ./charts-cluster/capvs-vanilla-cluster \
  -n capi-demo --create-namespace \
  -f my-values.yaml
```

Проверка:

```bash
kubectl -n capi-demo get cluster,machinedeployment,machine
kubectl -n capi-demo get kubeadmcontrolplane demo-control-plane -w
```

## Точка входа API без kube-vip

`cluster.endpoint.host` — это **стабильный** адрес, который попадёт в
kubeconfig и в join-конфигурацию worker-узлов. Для HA-кластера нельзя
указывать IP одного из control-plane узлов: при его недоступности кластер
потеряет API.

Варианты:

| Вариант | HA | kube-vip | Как задать | Ограничения |
|---|---|---|---|---|
| Внешний L4-балансировщик | да | нет | `cluster.endpoint.host` = IP/DNS LB | нужен внешний LB, TCP 6443, health check |
| kube-vip static pod | да | да | `kubeVip.enabled: true`, `cluster.endpoint.host` = VIP | L2-сеть, свободный IP, ARP |
| Один control plane + DHCP reservation | нет | нет | `controlPlane.replicas: 1`, endpoint = зарезервированный IP | нужна DHCP-резервация; нет HA |
| keepalived + HAProxy | да | нет | отдельный VIP/LB, endpoint = VIP | ставится и обслуживается отдельно |
| DNS с несколькими A | нет | нет | endpoint = DNS-имя | нет health check, риск неудачного bootstrap |
| BGP-анонс VIP | да | опционально | MetalLB/kube-vip BGP + endpoint = VIP | нужна настройка BGP на сети |

### 1. Внешний L4-балансировщик (рекомендуется для production)

Подходит HAProxy, F5, Citrix ADC, NSX Advanced Load Balancer, облачный LB.

- Режим — TCP passthrough на `6443`, без TLS termination.
- Health check — TCP `6443` на control-plane узлах.
- `cluster.endpoint.host` — IP или DNS-имя LB.
- `controlPlane.replicas: 3` (или 5).
- Если LB публикует `443` и проксирует на `6443`, задайте
  `cluster.endpoint.port: 443`; kube-apiserver продолжает слушать `6443`.
- LB должен заранее знать все control-plane узлы как backend (или уметь
  добавлять их по DNS), иначе первый `kubeadm init` может ждать API за LB,
  пока ни один backend ещё не healthy. Если это неудобно, используйте
  kube-vip или одиночный control plane.

```yaml
cluster:
  endpoint:
    host: capi-demo.example.com
    port: 6443

controlPlane:
  replicas: 3

kubeVip:
  enabled: false
```

Никаких дополнительных объектов в кластере чарт не создаёт.

### 2. Один control plane с DHCP-резервацией (без LB и без kube-vip)

Самый минимальный вариант без дополнительных компонентов. Нужна
DHCP-резервация: адрес control-plane узла должен быть известен до установки.

```yaml
cluster:
  endpoint:
    host: 10.0.0.50          # зарезервированный DHCP-адрес CP

controlPlane:
  replicas: 1
  network:
    devices:
      - networkName: /Datacenter/network/VM Network
        dhcp4: true

workerNodes:
  workers:
    replicas: 1
```

Если одиночный control-plane узел будет пересоздан, его IP должен
сохраниться (DHCP reservation), иначе `cluster.endpoint.host` станет
неверным.

CAPV `v1beta2` **не разрешает `ipAddrs` в `VSphereMachineTemplate`**
(webhook: `cannot be set in templates`). Для статических адресов без DHCP
используйте IPAM (`addressesFromPools`) или отдельные `VSphereMachine`
вместо шаблона; чарт поддерживает первый вариант.

### 2a. Статические адреса через CAPV IPAM (без kube-vip)

Если в management-кластере установлен IPAM-провайдер, можно раздавать
адреса из пула:

```yaml
controlPlane:
  replicas: 1
  network:
    devices:
      - networkName: /Datacenter/network/VM Network
        dhcp4: false
        addressesFromPools:
          - apiGroup: ipam.cluster.x-k8s.io
            kind: InClusterIPPool
            name: cp-pool

workerNodes:
  workers:
    replicas: 2
    network:
      devices:
        - networkName: /Datacenter/network/VM Network
          dhcp4: false
          addressesFromPools:
            - apiGroup: ipam.cluster.x-k8s.io
              kind: InClusterIPPool
              name: workers-pool
```

`cluster.endpoint.host` должен совпадать с адресом, который IPAM выдаст
control-plane узлу. Пул чарт не создаёт.

### 3. kube-vip (опционально, встроено в чарт)

kube-vip запускается как static pod на control-plane узлах и поднимает VIP
в ARP-режиме.

```yaml
cluster:
  endpoint:
    host: 10.0.0.50       # свободный VIP, не из DHCP-пула

controlPlane:
  replicas: 3

kubeVip:
  enabled: true
  interface: ens192       # частый интерфейс в VMware; проверьте ip -br a
```

Требования:

- VIP и control-plane узлы в одной L2-сети;
- VIP не должен выдаваться DHCP;
- `kubeVip.interface` должен смотреть в нужную сеть;
- образ kube-vip доступен узлам (`ghcr.io/kube-vip/kube-vip:v1.3.1` по
  умолчанию; в air-gapped среде переопределите `kubeVip.image`, например
  `r.shturval.tech/kube-vip:v1.2.4-326534`).

Чарт добавляет в `KubeadmControlPlane`:

- манифест static pod `/etc/kubernetes/manifests/kube-vip.yaml`;
- `/etc/kube-vip.hosts`;
- скрипт `/etc/pre-kubeadm-commands/50-kube-vip-prepare.sh` — upstream
  workaround для kubeadm >= 1.29 (переключение на `super-admin.conf` во время
  `kubeadm init`).

Если kube-vip не нужен, ничего включать не надо: по умолчанию
`kubeVip.enabled: false`.

### 4. keepalived + HAProxy

Классическая альтернатива kube-vip: keepalived держит VIP, HAProxy
балансирует `6443` между control-plane узлами. Можно ставить как systemd
сервисы на узлах или отдельными VM. Чарт это не создаёт; в
`cluster.endpoint.host` указывается VIP/адрес HAProxy.

### 5. DNS round-robin

DNS-имя с несколькими A-записями на control-plane узлы. Работает без
health check: клиент может попасть на недоступный узел. Для bootstrap и
production не рекомендуется; используйте только если DNS сам умеет
health-check (например, внешний LB с DNS).

### 6. BGP

Если L2-сети между узлами нет, VIP можно анонсировать по BGP через
MetalLB или kube-vip в BGP-режиме. Требуется настройка BGP-пиров на
сетевом оборудовании. В этом чарте kube-vip настроен только на ARP;
BGP-вариант ставится отдельно.

## Ключевые значения

### `cluster`

| Ключ | Назначение |
|---|---|
| `name` | Имя CAPI-кластера. Пусто => `Release.Name`; максимум 52 символа |
| `kubernetesVersion` | Версия Kubernetes без `v` |
| `podCIDR`, `serviceCIDR` | Сети кластера; должны совпадать с CNI |
| `serviceDomain` | DNS-домен сервисов (обычно `cluster.local`) |
| `endpoint.host` | LB/VIP/IP единственного control-plane |
| `endpoint.port` | Порт API снаружи (обычно `6443`) |

### `vsphere`

| Ключ | Назначение |
|---|---|
| `server` | vCenter, можно с портом |
| `thumbprint` | SHA-1 сертификата vCenter. Пусто => TLS не проверяется |
| `username`, `password` | Креды vCenter |
| `credentials.create` | Создать Secret с кредами |
| `credentials.existingSecret` | Использовать существующий Secret (ключи `username`, `password`) |
| `credentials.keepOnUninstall` | Не удалять Secret при `helm uninstall` (по умолчанию `true`) |
| `datacenter`, `datastore`, `folder`, `resourcePool` | Размещение VM |
| `template` | VM-шаблон с cloud-init + containerd + kubeadm + kubelet |
| `cloneMode` | `linkedClone` или `fullClone` |
| `powerOffMode` | `hard`, `soft`, `trySoft` |
| `storagePolicyName` | vSphere storage policy (опционально) |
| `network.devices` | Сеть по умолчанию для всех групп |
| `vm` | Размер VM по умолчанию |

Получить thumbprint:

```bash
openssl s_client -connect vcenter.example.com:443 </dev/null 2>/dev/null \
  | openssl x509 -fingerprint -sha1 -noout
```

CAPV ожидает SHA-1 в верхнем регистре через двоеточие. Пустой thumbprint
означает `insecure`; для production так делать не стоит.

### `controlPlane`

| Ключ | Назначение |
|---|---|
| `replicas` | Число control-plane узлов (1, 3, 5) |
| `vm`, `network`, `datacenter`, ... | Переопределения `vsphere.*` для control plane |
| `labels` | Метки Node (kubelet `--node-labels`) |
| `taints` | Taints Node |
| `kubeletExtraArgs` | Доп. аргументы kubelet |
| `extraSpec` | Произвольные поля `VSphereMachineTemplate.spec.template.spec` |
| `extraFiles` | Файлы в `KubeadmConfigSpec.files` |
| `extraPreKubeadmCommands`, `extraPostKubeadmCommands` | Доп. команды |
| `rollout.maxSurge`, `rollout.after` | Параметры rolling update KCP |
| `machineHealthCheck` | MHC для control plane (по умолчанию выключен) |

`vm` группы мержится с `vsphere.vm`: поля группы важнее. `network` группы
заменяет глобальную сеть целиком.

### `workerNodes`

Map: ключ — имя группы. Для каждой группы создаются отдельные
`MachineDeployment`, `KubeadmConfigTemplate`, `VSphereMachineTemplate` и,
опционально, `MachineHealthCheck`.

```yaml
workerNodes:
  workers:
    replicas: 3
    vm:
      numCPUs: 4
      memoryMiB: 8192
      diskGiB: 80
    labels:
      node-role.kubernetes.io/worker: ""
    taints:
      - key: dedicated
        value: workers
        effect: NoSchedule

  gpu:
    replicas: 1
    vm:
      numCPUs: 16
      memoryMiB: 65536
      diskGiB: 200
    labels:
      node-role.kubernetes.io/gpu: ""
```

Доступные ключи группы повторяют `controlPlane`: `vm`, `network`,
`datacenter`, `datastore`, `folder`, `resourcePool`, `template`, `server`,
`thumbprint`, `cloneMode`, `powerOffMode`, `storagePolicyName`, `labels`,
`taints`, `kubeletExtraArgs`, `extraSpec`, `extraFiles`,
`extraPreKubeadmCommands`, `extraPostKubeadmCommands`, `deletion`, `rollout`,
`templateAnnotations`, `machineHealthCheck`.

### `kubeVip`

| Ключ | Назначение |
|---|---|
| `enabled` | Включить static pod kube-vip |
| `image` | Образ kube-vip |
| `interface` | Сетевой интерфейс для VIP |
| `cidr` | Маска VIP (32 для IPv4) |
| `services.enabled` | Использовать kube-vip и для Service type=LoadBalancer |
| `extraEnv` | Доп. env kube-vip |

### `kubeadm`

| Ключ | Назначение |
|---|---|
| `imageRepository` | Репозиторий образов control plane (air-gapped) |
| `skipKubeProxy` | Не устанавливать kube-proxy (для Cilium kube-proxy replacement) |
| `apiServer.extraArgs` | Доп. аргументы kube-apiserver |
| `apiServer.certSANs` | Доп. SAN |
| `apiServer.imageRepository`, `apiServer.imageTag` | Переопределить образ kube-apiserver |
| `controllerManager.extraArgs` | Доп. аргументы controller-manager |
| `controllerManager.imageRepository`, `controllerManager.imageTag` | Переопределить образ kube-controller-manager |
| `scheduler.extraArgs` | Доп. аргументы scheduler |
| `etcd.local.dataDir` | Каталог etcd |
| `etcd.local.imageRepository`, `etcd.local.imageTag` | Переопределить образ etcd (air-gapped) |
| `dns.imageTag` | Версия CoreDNS (пусто => default kubeadm) |

#### Переопределение образов kube-apiserver и kube-controller-manager

Kubeadm не поддерживает отдельные `imageRepository`/`imageTag` для
`kube-apiserver` и `kube-controller-manager`: есть только глобальный
`kubeadm.imageRepository` и версия control plane из
`cluster.kubernetesVersion`. Поэтому чарт реализует переопределение через
**kubeadm patches** — strategic merge patch для static Pod манифестов:

```yaml
kubeadm:
  # глобальный registry для всех control plane образов
  imageRepository: r.shturval.tech

  apiServer:
    imageRepository: registry.example.com/k8s
    imageTag: v1.36.5

  controllerManager:
    imageRepository: registry.example.com/k8s
    imageTag: v1.36.5
```

Чарт создаёт файлы:

- `/etc/kubernetes/patches/kube-apiserver.yaml`
- `/etc/kubernetes/patches/kube-controller-manager.yaml`

и указывает `patches.directory` в `initConfiguration`/`joinConfiguration`.
Если задан только `imageRepository`, тег берётся как `v<cluster.kubernetesVersion>`.
Если задан только `imageTag`, репозиторий берётся из `kubeadm.imageRepository`
(или `registry.k8s.io`).

> Не используйте разные версии apiserver и controller-manager без
> необходимости: control plane рассчитан на одну версию Kubernetes.
> Переопределение тега имеет смысл для зеркал/патченных образов той же
> версии.
>
> Патчи применяются при bootstrap и join control-plane узлов. После
> `kubeadm upgrade` проверьте фактические образы в static Pod манифестах;
> при необходимости пересоздайте control plane через
> `controlPlane.rollout.after`.

### `ssh` и `ntp`

```yaml
ssh:
  enabled: true
  user: capv
  authorizedKeys:
    - "ssh-ed25519 AAAA... user@example"

ntp:
  enabled: true
  servers:
    - ntp1.example.com
    - ntp2.example.com
```

## Сеть и статические IP

### DHCP (по умолчанию)

```yaml
vsphere:
  network:
    devices:
      - networkName: /Datacenter/network/VM Network
        dhcp4: true
```

### DHCP-резервация

Для одной или нескольких VM проще всего зарезервировать адреса по MAC в
DHCP. В values остаётся `dhcp4: true`, а `cluster.endpoint.host` указывает
на зарезервированный адрес control-plane узла.

### CAPV IPAM

CAPV `v1beta2` запрещает `ipAddrs` в `VSphereMachineTemplate`. Для
статических адресов используйте `addressesFromPools` с установленным
IPAM-провайдером, например `cluster-api-provider-ipam`:

```yaml
workerNodes:
  workers:
    replicas: 3
    network:
      devices:
        - networkName: /Datacenter/network/VM Network
          dhcp4: false
          addressesFromPools:
            - apiGroup: ipam.cluster.x-k8s.io
              kind: InClusterIPPool
              name: workers-pool
```

Пул `InClusterIPPool` чарт не создаёт — он должен существовать в
management-кластере (или создаваться отдельным чартом/манифестом).

## MachineHealthCheck

MHC выключен по умолчанию. Пример для worker-группы:

```yaml
workerNodes:
  workers:
    replicas: 3
    machineHealthCheck:
      enabled: true
      checks:
        nodeStartupTimeoutSeconds: 600
        unhealthyNodeConditions:
          - type: Ready
            status: "False"
            timeoutSeconds: 300
          - type: Ready
            status: Unknown
            timeoutSeconds: 300
      remediation:
        triggerIf:
          unhealthyLessThanOrEqualTo: 1
```

`unhealthyLessThanOrEqualTo` защищает от массового удаления узлов: при
большем числе unhealthy-машин remediation не срабатывает. Для control plane
аналогичный блок — `controlPlane.machineHealthCheck`.

## После установки

### Kubeconfig

CAPI создаёт Secret `<cluster>-kubeconfig`:

```bash
kubectl -n capi-demo get secret demo-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > demo.kubeconfig

export KUBECONFIG=$PWD/demo.kubeconfig
kubectl get nodes -o wide
```

### CNI (обязательно)

Пока CNI не установлен, узлы будут `NotReady`, а CoreDNS — в `Pending`.
Установите один из вариантов.

Cilium:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium -n kube-system \
  --set k8sServiceHost=10.0.0.50 \
  --set k8sServicePort=6443
```

Calico:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/master/manifests/calico.yaml
```

Flannel:

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

`podCIDR` в values должен совпадать с пулом CNI (для Calico по умолчанию
`192.168.0.0/16`, как в примере).

Если в VM-образе нет `iptables` и `kube-proxy` падает, используйте
kube-proxy replacement в Cilium:

```yaml
kubeadm:
  skipKubeProxy: true
```

```bash
helm install cilium cilium/cilium -n kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=10.0.0.50 \
  --set k8sServicePort=6443
```

В этом сценарии kube-proxy DaemonSet не создаётся вообще (если кластер
создаётся заново).

### CSI и CPI

Чарт не устанавливает vSphere CSI и Cloud Provider Interface.

- Для динамических PV нужен vSphere CSI driver и Secret `vsphere-config-secret`
  в namespace `vmware-system-csi`.
- vSphere CPI добавляет topology-метки (`topology.kubernetes.io/zone`,
  `instance-type`) и интеграцию с vSphere. Без CPI базовый кластер работает,
  но CSI/zone-aware scheduling могут требовать CPI.
- Официальный CAPV-шаблон ставит CPI/CSI через `ClusterResourceSet`; здесь
  этого сознательно нет.

## Обновление

Версия Kubernetes:

```yaml
cluster:
  kubernetesVersion: "1.37.0"
```

`helm upgrade` обновит `KubeadmControlPlane` и `MachineDeployment`; CAPI
выполнит rolling update.

Изменение `vm`, `template`, `extraSpec` и других полей
`VSphereMachineTemplate` **не пересоздаёт существующие машины**: CAPI
использует шаблон только для новых машин. Чтобы принудительно обновить
группу:

- control plane — задайте `controlPlane.rollout.after` (RFC3339, например
  текущее время) и сделайте `helm upgrade`;
- worker-группа — измените `workerNodes.<group>.templateAnnotations`
  (например, `capi.capvs-vanilla-cluster/rollout: "2026-11-18"`) и сделайте
  `helm upgrade`.

После rollout можно убрать/обновить значение.

## Удаление

```bash
helm uninstall demo -n capi-demo
```

CAPI/CAPV удалят Machine и VM. Secret с кредами vCenter по умолчанию
сохраняется (`vsphere.credentials.keepOnUninstall: true`), потому что CAPV
использует его для удаления VM. После того как все Machine исчезли, Secret
можно удалить вручную:

```bash
kubectl -n capi-demo get machines
kubectl -n capi-demo delete secret demo-vsphere-credentials
```

Если Secret должен удаляться вместе с релизом, задайте
`vsphere.credentials.keepOnUninstall: false`. Но тогда сначала дождитесь
удаления Machine, иначе CAPV может не суметь удалить VM в vCenter.

Не удаляйте namespace, пока CAPI не завершил удаление Machine: иначе
контроллеры не смогут корректно очистить VM в vCenter. Дождитесь:

```bash
kubectl -n capi-demo get machines
```


## Отличия от `capvs-cluster` (Штурвал)

| `capvs-cluster` | `capvs-vanilla-cluster` |
|---|---|
| `ClusterConfig`, `InfrastructureProvider` | нет |
| `shturvald`, NCI, `nci.json` | нет |
| `licensetoken`, `systemregistry`, `shturvalReleaseVersion` | нет |
| список сервисов Штурвала | нет |
| kube-vip включён через NCI | kube-vip опционален и выключен |
| CAPI/CAPV `v1beta1` | CAPI/CAPV `v1beta2` |
| namespace = имя релиза, отдельно от namespace Helm | namespace = namespace Helm-релиза |
| `VSphereClusterIdentity` + Secret в `capv-system` | Secret в namespace кластера + `identityRef.kind: Secret` |
| Shturval cluster-autoscaler | нет (ставьте отдельно) |
| Shturval services / ingress / monitoring | нет |

## Безопасность

- Не оставляйте `vsphere.thumbprint` пустым в production: пустое значение
  означает подключение к vCenter без проверки TLS.
- Пароль vCenter в `values.yaml` — удобно для теста, но не для production.
  Создайте Secret отдельно (SealedSecret, External Secrets, SOPS) и укажите
  `vsphere.credentials.create: false` + `existingSecret`.
- Чарт не включает audit, encryption-at-rest и hardening kube-apiserver.
  Добавляйте их осознанно через `kubeadm.apiServer.extraArgs` и
  `controlPlane.extraFiles` (или kubeadm-патчи в образе).
- Доступ к management-кластеру = доступ к кластерам и их kubeconfig.
  Ограничьте RBAC на namespace, в котором живут CAPI-объекты.

## Ограничения

- Чарт не создаёт management-кластер и не устанавливает CAPI/CAPV. Он
  предполагает, что они уже есть.
- Нет встроенного CNI/CSI/CPI/ingress/monitoring.
- Нет ClusterClass/topology: используется классическая схема
  `Cluster + KubeadmControlPlane + MachineDeployment`.
- `kube-vip` реализован только в ARP-режиме.
- IPv4 — основной поддерживаемый сценарий; IPv6 в vSphere-сети и kube-vip
  требует отдельной проверки.
- CAPV `v1beta2` запрещает `ipAddrs` в `VSphereMachineTemplate`.
  Чарт останавливает рендер при `ipAddrs`; используйте DHCP-резервацию
  или `addressesFromPools`.
- Чарт не настраивает audit, encryption-at-rest и hardening. Для этого
  используйте `kubeadm.*` и `controlPlane.extraFiles` или отдельные
  kubeadm-патчи.
