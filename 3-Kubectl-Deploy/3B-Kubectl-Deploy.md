
## 3. Create namespaces and GHCR secret

```bash
kubectl create namespace staging --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -

read -s GITHUB_PAT

kubectl create secret docker-registry github-registry-secret \
  --namespace=staging \
  --docker-server=ghcr.io \
  --docker-username=KeremAR \
  --docker-password="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Create the same secret in `production` before deploying production.

---

## 4. Deploy staging

```bash
kubectl apply -R -f 3-Kubectl-Deploy/staging
kubectl get pods -n staging -w
```

Rollouts intentionally pause at the manual canary gate:

```bash
kubectl argo rollouts get rollout frontend -n staging
kubectl argo rollouts promote frontend -n staging --full
kubectl argo rollouts promote user-service -n staging --full
kubectl argo rollouts promote todo-service -n staging --full
```

App URL:

```text
http://todo-app-staging.192.168.0.110.nip.io
```

---

## 5. Quick checks

```bash
kubectl get pods,pvc,httproute -n staging
kubectl exec -n staging user-db-0 -- psql -U userservice -d userdb -c '\dt'
kubectl exec -n staging todo-db-0 -- psql -U todoservice -d tododb -c '\dt'
```

If DB tables are missing, restart the service after PostgreSQL is ready:

```bash
kubectl argo rollouts restart user-service -n staging
kubectl argo rollouts restart todo-service -n staging
kubectl argo rollouts promote user-service -n staging --full
kubectl argo rollouts promote todo-service -n staging --full
```

Known follow-up: backend `init_db()` can run before PostgreSQL is ready and does not retry. Later, add DB/schema-aware readiness checks or move schema creation into a migration/init Job.

---

## Notes

- Staging manifests are adjusted for this CAPI cluster and should not contain the old `k3s-worker` node selector.
- Before using production manifests, remove any stale `k3s-worker` node selectors from production DB StatefulSets.
- `AnalysisTemplate` belongs to Argo Rollouts and runs canary health checks before promotion.
- Later CI/CD direction: app code and Kubernetes config will be split; pipeline will deploy by `SERVICE`, `ENV`, `BRANCH`, and `IMAGE_TAG`.