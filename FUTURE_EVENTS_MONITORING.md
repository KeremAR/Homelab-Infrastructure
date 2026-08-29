Events Zahmeti
Senin Events ekranını manuel takip etmen gerekmemeli. Mevcut [alloy-logs-config.yaml](/mnt/c/Users/kerem/Documents/infrastructure/8_Observability-Stack/logs/alloy-logs-config.yaml) sadece pod dosya loglarını topluyor; Kubernetes Events toplamıyor.
Alloy’a loki.source.kubernetes_events eklenerek şunlar Elasticsearch/Kibana’ya gönderilebilir:
- Unhealthy
- FailedScheduling
- FailedMount
- FailedAttachVolume
- BackOff
- ImagePullBackOff
- probe timeout ve connection refused mesajları
Alloy bunun için hazır bir Kubernetes Events kaynağı sağlıyor. [Alloy Kubernetes Events kaynağı](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.kubernetes_events/)
Alloy şu anda DaemonSet olduğu için event collector’ı her replica üzerinde doğrudan açarsak aynı event birden fazla kez gelebilir. Bunu ya Alloy clustering ile ya da ayrı, tek replikalı bir event-collector deployment’ıyla kurmak gerekir. Bence sonraki doğru adım bu: başarısız probe response’larını uygulamada loglamak, kubelet kaynaklı probe ve pod olaylarını da Alloy üzerinden Elasticsearch’e taşımak.