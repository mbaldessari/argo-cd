#!/bin/bash

# Improved reproduction script for ArgoCD SelfHeal Bug #18442
# This script demonstrates that selfHeal=true doesn't work after a failed sync

set -e

echo "🔍 Reproducing ArgoCD SelfHeal Bug #18442 (Improved)"
echo "=================================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NS=openshift-gitops

# Check prerequisites
echo "📋 Checking prerequisites..."
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl not found${NC}"
    exit 1
fi

if ! kubectl get namespace ${NS} &> /dev/null; then
    echo -e "${RED}❌ ArgoCD namespace not found. Please install ArgoCD first.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites satisfied${NC}"

# Cleanup any existing test
echo "🧹 Cleaning up any existing test resources..."
kubectl delete application.argoproj.io selfheal-bug-demo -n ${NS} --ignore-not-found=true
kubectl delete namespace selfheal-bug-test --ignore-not-found=true
sleep 5

# Step 1: Create test namespace WITHOUT auto-creation allowed
echo "🚀 Step 1: Creating test environment..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: selfheal-bug-test
  labels:
    name: selfheal-bug-test
---
# Create a network policy that will cause issues
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: selfheal-bug-test
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  # This denies all traffic, which may cause deployment issues
---
# Create a restrictive resource quota
apiVersion: v1
kind: ResourceQuota
metadata:
  name: failing-quota
  namespace: selfheal-bug-test
spec:
  hard:
    requests.cpu: "1m"        # Extremely low CPU - guestbook needs ~100m
    requests.memory: "1Mi"    # Extremely low memory - guestbook needs ~64Mi
    limits.cpu: "5m"
    limits.memory: "5Mi"
    pods: "1"                 # Only 1 pod - guestbook has frontend + backend
EOF

echo -e "${GREEN}✅ Test namespace with restrictive policies created${NC}"

# Step 2: Create ArgoCD application with selfHeal enabled but MORE IMPORTANTLY no CreateNamespace
echo "🎯 Step 2: Creating ArgoCD application with selfHeal=true..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: selfheal-bug-demo
  namespace: ${NS}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: selfheal-bug-test
  syncPolicy:
    automated:
      prune: true
      selfHeal: true    # This is the key setting we're testing
    syncOptions:
    - CreateNamespace=false  # Don't auto-create namespace
    - ApplyOutOfSyncOnly=true
    retry:
      limit: 2          # Allow a couple retries before giving up
EOF

echo -e "${GREEN}✅ ArgoCD application created${NC}"

# Step 3: Wait for the sync to fail and check status multiple times
echo "⏳ Step 3: Waiting for sync to fail due to resource constraints..."
sleep 5

# Function to check app status
check_app_status() {
    local attempt=$1
    echo -e "${BLUE}📊 Status check #${attempt}:${NC}"

    HEALTH=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    SYNC_STATUS=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    OPERATION_PHASE=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo "None")

    echo "   Health: $HEALTH"
    echo "   Sync: $SYNC_STATUS"
    echo "   Operation: $OPERATION_PHASE"

    # Check for specific conditions
    CONDITIONS=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
    if [[ "$CONDITIONS" == *"SyncError"* ]]; then
        echo -e "   ${RED}⚠️  Has SyncError condition${NC}"
        SYNC_ERROR_MSG=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.conditions[?(@.type=="SyncError")].message}' 2>/dev/null)
        echo "   Error: $SYNC_ERROR_MSG"
        return 1  # Indicates sync error found
    fi

    return 0
}

# Check status multiple times to catch the failure
HAS_SYNC_ERROR=false
for i in {1..6}; do
    sleep 10
    if ! check_app_status $i; then
        HAS_SYNC_ERROR=true
        break
    fi
done

if [ "$HAS_SYNC_ERROR" = false ]; then
    echo -e "${YELLOW}⚠️  No sync error detected yet. The app might be syncing successfully.${NC}"
    echo "   This could mean:"
    echo "   1. The resource quota isn't restrictive enough"
    echo "   2. ArgoCD is handling the constraints better than expected"
    echo "   3. The bug might already be fixed in this version"

    # Let's try a different approach - create a conflicting resource
    echo "🔄 Trying alternative failure method..."

    # Create a conflicting deployment
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: guestbook-ui
  namespace: selfheal-bug-test
  labels:
    app: guestbook-ui
    conflict: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: conflicting-guestbook
  template:
    metadata:
      labels:
        app: conflicting-guestbook
    spec:
      containers:
      - name: guestbook-ui
        image: gcr.io/heptio-images/ks-guestbook-demo:0.1
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 10m
            memory: 10Mi
EOF

    # Force sync to cause conflict
    echo "🔧 Forcing sync to create conflict..."
    kubectl patch application.argoproj.io selfheal-bug-demo -n ${NS} --type merge -p '{"spec":{"syncPolicy":{"syncOptions":["Replace=true"]}}}'

    # Wait and check again
    sleep 15
    check_app_status "after-conflict"
fi

# Step 4: Now fix the issue to test selfHeal
echo ""
echo -e "${YELLOW}🔧 Step 4: Removing constraints to fix the underlying issue...${NC}"

# Remove quota and network policy
kubectl delete resourcequota failing-quota -n selfheal-bug-test --ignore-not-found=true
kubectl delete networkpolicy deny-all -n selfheal-bug-test --ignore-not-found=true
kubectl delete deployment guestbook-ui -n selfheal-bug-test --ignore-not-found=true

echo -e "${GREEN}✅ Constraints removed - sync should now be possible${NC}"

# Step 5: Wait and observe selfHeal behavior
echo ""
echo -e "${YELLOW}⏳ Step 5: Waiting to see if selfHeal retries automatically...${NC}"
echo "   With selfHeal=true, ArgoCD should automatically retry the sync."
echo "   Due to bug #18442, it might not retry after a failed sync."
echo ""

# Wait longer and check status more frequently
echo "   Monitoring for 2 minutes..."
for i in {1..24}; do
    sleep 5
    echo -n "."
    if [ $((i % 6)) -eq 0 ]; then
        echo " (${i}0s)"
        CURRENT_STATUS=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        echo "     Current status: $CURRENT_STATUS"
    fi
done
echo ""

# Step 6: Final status check
echo "📊 Step 6: Final selfHeal test results..."
FINAL_SYNC_STATUS=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.sync.status}')
FINAL_HEALTH=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.health.status}')

echo "   Final Sync Status: $FINAL_SYNC_STATUS"
echo "   Final Health: $FINAL_HEALTH"

if [ "$FINAL_SYNC_STATUS" = "Synced" ] && [ "$FINAL_HEALTH" = "Healthy" ]; then
    echo -e "${GREEN}✅ SelfHeal worked! App is now synced and healthy.${NC}"
    echo -e "${GREEN}   This suggests the bug might be fixed in this version.${NC}"
else
    echo -e "${RED}❌ SelfHeal did NOT work automatically${NC}"
    echo -e "${RED}   Status: $FINAL_SYNC_STATUS, Health: $FINAL_HEALTH${NC}"
    echo -e "${RED}   This confirms bug #18442 exists${NC}"
fi

# Step 7: Test manual sync to prove it's fixable
echo ""
echo "🔨 Step 7: Testing manual sync (should work if constraints are removed)..."

# Trigger manual sync with proper parameters
kubectl patch application.argoproj.io selfheal-bug-demo -n ${NS} --type merge -p '{
  "operation": {
    "sync": {
      "revision": "HEAD",
      "syncStrategy": {
        "apply": {
          "force": false
        }
      }
    }
  }
}'

# Wait for manual sync
echo "   Waiting for manual sync to complete..."
sleep 15

MANUAL_SYNC_STATUS=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.sync.status}')
MANUAL_HEALTH=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.health.status}')

echo "   Manual sync result - Status: $MANUAL_SYNC_STATUS, Health: $MANUAL_HEALTH"

if [ "$MANUAL_SYNC_STATUS" = "Synced" ] && [ "$MANUAL_HEALTH" = "Healthy" ]; then
    echo -e "${GREEN}✅ Manual sync worked!${NC}"
    if [ "$FINAL_SYNC_STATUS" != "Synced" ]; then
        echo -e "${RED}🐛 This proves the bug: manual sync works but selfHeal didn't${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Manual sync also having issues. May be environmental.${NC}"
fi

# Step 8: Check ArgoCD logs for the bug signature
echo ""
echo "🔍 Step 8: Checking ArgoCD controller logs for bug evidence..."

# Look for the specific log message that indicates the bug
LOG_RESULT=$(kubectl logs -n ${NS} deployment/openshift-gitops-application-controller --tail=100 2>/dev/null | grep -i "selfheal-bug-demo" | grep -E "(skipping auto-sync.*failed|will not retry)" || echo "")

if [ -n "$LOG_RESULT" ]; then
    echo -e "${RED}🎯 Found bug signature in logs:${NC}"
    echo "$LOG_RESULT"
else
    echo "No specific bug signature found in recent logs"
    echo "Recent ArgoCD logs for this app:"
    kubectl logs -n ${NS} deployment/openshift-gitops-application-controller --tail=50 2>/dev/null | grep -i "selfheal-bug-demo" || echo "No recent logs found"
fi

# Summary
echo ""
echo "📋 REPRODUCTION SUMMARY"
echo "======================="
echo "App final status: $FINAL_SYNC_STATUS / $FINAL_HEALTH"
echo "Manual sync status: $MANUAL_SYNC_STATUS / $MANUAL_HEALTH"

if [ "$FINAL_SYNC_STATUS" != "Synced" ] && [ "$MANUAL_SYNC_STATUS" = "Synced" ]; then
    echo -e "${RED}🐛 BUG CONFIRMED: SelfHeal failed but manual sync worked${NC}"
elif [ "$FINAL_SYNC_STATUS" = "Synced" ]; then
    echo -e "${GREEN}✅ SelfHeal worked - bug might be fixed${NC}"
else
    echo -e "${YELLOW}⚠️  Inconclusive - both selfHeal and manual sync had issues${NC}"
fi

# Cleanup
echo ""
echo "🧹 Cleanup:"
echo "   kubectl delete application.argoproj.io selfheal-bug-demo -n ${NS}"
echo "   kubectl delete namespace selfheal-bug-test"