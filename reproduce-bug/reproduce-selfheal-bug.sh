#!/bin/bash

# Reproduction script for ArgoCD SelfHeal Bug #18442
# This script demonstrates that selfHeal=true doesn't work after a failed sync

set -ex

echo "🔍 Reproducing ArgoCD SelfHeal Bug #18442"
echo "=========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Step 1: Create test namespace and restrictive quota
echo "🚀 Step 1: Creating test environment..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: selfheal-bug-test
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: failing-quota
  namespace: selfheal-bug-test
spec:
  hard:
    requests.cpu: "5m"       # Impossibly low CPU - will cause failures
    requests.memory: "5Mi"   # Impossibly low memory - will cause failures
    pods: "1"                # Only 1 pod allowed - guestbook needs more
EOF

echo -e "${GREEN}✅ Test namespace and restrictive quota created${NC}"

# Step 2: Create ArgoCD application with selfHeal enabled
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
      selfHeal: true
    retry:
      limit: 1
EOF

echo -e "${GREEN}✅ ArgoCD application created${NC}"

# Step 3: Wait for the sync to fail
echo "⏳ Step 3: Waiting for sync to fail due to resource quota..."
sleep 10

# Check application status
echo "📊 Step 4: Checking application status..."
kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.sync.status}' || echo "Status check failed"

echo ""
echo "🔍 Application conditions:"
kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.conditions}' | jq '.' 2>/dev/null || echo "No conditions or jq not available"

# Step 5: Remove the quota to fix the issue
echo ""
echo -e "${YELLOW}🔧 Step 5: Removing resource quota to fix the underlying issue...${NC}"
kubectl delete resourcequota failing-quota -n selfheal-bug-test

echo -e "${GREEN}✅ Resource quota removed - sync should now be possible${NC}"

# Step 6: Wait and observe that selfHeal doesn't work
echo ""
echo -e "${YELLOW}⏳ Step 6: Waiting to see if selfHeal retries automatically...${NC}"
echo "   With selfHeal=true, ArgoCD should automatically retry the sync."
echo "   Due to bug #18442, it won't retry after a failed sync."
echo ""
echo "   Waiting 60 seconds..."

for i in {1..12}; do
    sleep 5
    echo -n "."
done
echo ""

# Check if it's still failed
echo "📊 Step 7: Checking if selfHeal worked..."
SYNC_STATUS=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.sync.status}')

if [ "$SYNC_STATUS" = "Synced" ]; then
    echo -e "${GREEN}✅ selfHeal worked! (Bug might be fixed)${NC}"
else
    echo -e "${RED}❌ selfHeal did NOT work - application is still: $SYNC_STATUS${NC}"
    echo -e "${RED}   This confirms bug #18442${NC}"
fi

# Step 8: Show that manual sync works
echo ""
echo "🔨 Step 8: Testing manual sync (should work)..."
kubectl patch application.argoproj.io selfheal-bug-demo -n ${NS} --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'

# Wait a bit for manual sync
sleep 10

FINAL_STATUS=$(kubectl get application.argoproj.io selfheal-bug-demo -n ${NS} -o jsonpath='{.status.sync.status}')
echo "📊 Final status after manual sync: $FINAL_STATUS"

if [ "$FINAL_STATUS" = "Synced" ]; then
    echo -e "${GREEN}✅ Manual sync worked, proving the issue was temporary${NC}"
    echo -e "${RED}❌ But selfHeal should have done this automatically!${NC}"
else
    echo -e "${YELLOW}⚠️  Manual sync still in progress or failed${NC}"
fi

# Check ArgoCD logs for the specific error message
echo ""
echo "🔍 Step 9: Checking ArgoCD logs for the bug signature..."
kubectl logs -n ${NS} deployment/argocd-application-controller --tail=50 | grep -i "selfheal-bug-demo" | grep -i "skipping auto-sync.*failed previous sync" || echo "Bug signature not found in recent logs"

# Cleanup instructions
echo ""
echo "🧹 Cleanup Instructions:"
echo "   To clean up this test:"
echo "   kubectl delete application selfheal-bug-demo -n ${NS}"
echo "   kubectl delete namespace selfheal-bug-test"
echo ""
echo "🐛 Bug Summary:"
echo "   If selfHeal didn't automatically retry after removing the quota,"
echo "   but manual sync worked, then bug #18442 is confirmed."
