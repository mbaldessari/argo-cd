local hs = {}

if obj.metadata.deletionTimestamp ~= nil then
    hs.status = "Progressing"
    hs.message = "Backstage is terminating"
    return hs
end

if obj.status.conditions == nil then
    hs.status = "Progressing"
    hs.message = "Status conditions not found"
    return hs
end

if #obj.status.conditions == 0 then
    hs.status = "Progressing"
    hs.message = "Status conditions not found"
    return hs
end

for _, condition in pairs(obj.status.conditions) do
    if condition.type == "Deployed" and condition.status == "True" then
        hs.status = "Healthy"
        hs.message = "Backstage is healthy"
        return hs
    end
    if condition.type == "Deployed" and condition.status == "False" then
        hs.status = "Degraded"
        hs.message = "Backstage is degraded: " .. condition.message
        return hs
    end

end
