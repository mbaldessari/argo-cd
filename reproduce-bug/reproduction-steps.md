# Reproduction Steps for SelfHeal Bug #18442

## Prerequisites
- ArgoCD installed and running
- kubectl access to the cluster
- Git repository access (or use the built-in examples)

## Step 1: Create the test namespace
```bash
kubectl create namespace selfheal-test-ns
```

## Step 2: Apply the initial application (this should work)
```bash
kubectl apply -f 01-working-app.yaml
```

## Step 3: Wait for initial sync to complete
```bash
# Check that the app syncs successfully
argocd app get selfheal-test --refresh
```

## Step 4: Create a scenario that causes sync failures

### Method A: Resource Conflict (Recommended)
Create a conflicting resource manually that will cause sync failures:

```bash
# Create a conflicting service that ArgoCD will try to overwrite
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: guestbook-ui
  namespace: default
  annotations:
    argocd.argoproj.io/managed-by: "manual-conflict"  # This prevents ArgoCD from managing it
spec:
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: conflicting-service  # Different selector
  type: LoadBalancer  # Different type than what ArgoCD expects
EOF
```

### Method B: Permission Issue (Alternative)
```bash
# Remove ArgoCD's permission to manage the namespace
kubectl create rolebinding argocd-restrict --clusterrole=view --serviceaccount=argocd:argocd-application-controller -n default
# This will cause permission errors
```

## Step 5: Force a sync that will fail
```bash
# Force sync the application - this should fail due to conflicts
argocd app sync selfheal-test --force
```

## Step 6: Observe the failure and selfHeal behavior
```bash
# Check the application status - should show sync error
argocd app get selfheal-test

# Check the controller logs for the bug
kubectl logs -n argocd deployment/argocd-application-controller | grep -A5 -B5 "selfheal-test"
```

## Step 7: Fix the conflict and observe selfHeal should work but doesn't
```bash
# Remove the conflicting resource
kubectl delete service guestbook-ui -n default

# Wait and observe - selfHeal should retry but won't due to the bug
# You should see logs like:
# "Skipping auto-sync: failed previous sync attempt to [revision] and will not retry"
```

## Expected vs Actual Behavior

### Expected (with selfHeal=true):
- After fixing the conflict, ArgoCD should automatically retry the sync
- The application should eventually become synced

### Actual (due to bug):
- ArgoCD continues to skip auto-sync due to the previous failure
- Application remains in failed state indefinitely
- Logs show: "Skipping auto-sync: failed previous sync attempt to [revision] and will not retry"

### Workaround to confirm bug:
```bash
# Manual sync works (confirming the issue is resolved)
argocd app sync selfheal-test
# This should succeed, proving the conflict was resolved but selfHeal didn't work
```

## Clean up
```bash
kubectl delete -f 01-working-app.yaml
kubectl delete namespace selfheal-test-ns
```