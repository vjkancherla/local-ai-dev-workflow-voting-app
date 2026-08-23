R1   PASS     200 with exactly two options: Cats / Dogs
R2   PASS     POST /vote -> 200, redis LLEN 0 -> 1
R3   PASS     tally unchanged after re-vote (2)
R4   PASS     one row for verify-r4 after replay
R5   PASS     percentages + both option labels present
R6   PASS     vote appeared in 0s (limit 5s)
R7   PASS     votes table has voter_id, choice, updated_at
R8   PASS     queued vote (1) drained to postgres after restart
R9   PASS     tally preserved across restart (5)
R10  PASS     5 liveness + 5 readiness probes
R11  PASS     5 containers with cpu/mem requests + limits
R12  PASS     kustomize base + registry image override
R13  PASS     vote=200 result=200
R14  PASS     0 NodePort services
R15  PASS     arm64, no ImagePullBackOff (images imported)
R16  PASS     vote/result/worker/redis/postgres all healthy
R17  PASS     no literal password; Secret 'voting-app-postgres' holds POSTGRES_PASSWORD

===== 17 PASS, 0 FAIL =====
