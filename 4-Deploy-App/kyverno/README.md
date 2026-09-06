# Kyverno

Kyverno evaluates Kubernetes resources against policies written as Kubernetes
YAML. It is installed before the application so the same cluster-wide
guardrails apply whether workloads are deployed with plain manifests, Helm or
ArgoCD.

The starter policies in [`policies/`](./policies/) check that:

- application containers define CPU and memory requests and limits;
- privileged containers are not used;
- application images have an explicit tag other than `latest`.

All three policies start in `Audit` mode. Violating resources are reported but
are not rejected, which makes it safe to inspect the current cluster before
enforcing a rule. Mutation and resource-generation policies are intentionally
left for later because they change or create resources rather than only
reporting their condition.

## Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update kyverno

helm upgrade --install kyverno kyverno/kyverno \
  --version 3.9.0 \
  --namespace kyverno \
  --create-namespace \
  --values 4-Deploy-App/kyverno/values.yaml \
  --wait
```

Install the starter policies:

```bash
kubectl apply -f 4-Deploy-App/kyverno/policies/
```

## Verify the reports

```bash
kubectl get pods -n kyverno
kubectl get validatingpolicy
kubectl get policyreport -A
kubectl get clusterpolicyreport
```

Inspect the violations reported for an individual namespace:

```bash
kubectl describe policyreport -n production
```

When a policy is clean and should become a hard admission guardrail, change
only that policy's `validationActions` entry from `Audit` to `Deny` and apply
it again. Existing resources remain visible to background reporting; new or
updated non-compliant Pods are then rejected at admission.

## References

- [Kyverno installation](https://kyverno.io/docs/installation/installation/)
- [Policy reports](https://kyverno.io/docs/policy-reports/)
- [CEL-based ValidatingPolicy](https://kyverno.io/docs/policy-types/validating-policy/)
- [Kyverno sample policy library](https://kyverno.io/policies/)
