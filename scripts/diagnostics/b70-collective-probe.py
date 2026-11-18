import datetime
import os
import sys

import torch
import torch.distributed as dist

mode = sys.argv[1] if len(sys.argv) > 1 else "xccl"
assert mode in ("xccl", "hoststage")
rank = int(os.environ["LOCAL_RANK"])
assert int(os.environ["WORLD_SIZE"]) == 2


def log(message):
    print(f"{datetime.datetime.now(datetime.timezone.utc).isoformat()} rank={rank} {message}", flush=True)


log(f"torch={torch.__version__} mode={mode}")
log(str({k: v for k, v in os.environ.items() if k.startswith(("CCL_", "ZE_", "SYCL_", "UR_", "ONEAPI_"))}))
torch.xpu.set_device(rank)
log(f"device={torch.xpu.get_device_name(rank)}")
dist.init_process_group("xccl" if mode == "xccl" else "gloo", timeout=datetime.timedelta(seconds=60))
log("group ready")
for dtype in (torch.float32, torch.float16, torch.bfloat16):
    for count in (1, 31, 1024, 32768, 262144, 4194304):
        pattern = torch.arange(count, dtype=torch.int32).remainder_(31).to(dtype)
        for iteration in range(3):
            expected = pattern * 2 + 3 + 2 * iteration
            tensor = (pattern + rank + 1 + iteration).to(f"xpu:{rank}")
            torch.xpu.synchronize()
            log(f"begin dtype={dtype} elements={count} iteration={iteration}")
            if mode == "xccl":
                dist.all_reduce(tensor)
            else:
                staged = tensor.cpu()
                dist.all_reduce(staged)
                tensor.copy_(staged)
            torch.xpu.synchronize()
            result = tensor.cpu()
            if not torch.equal(result, expected):
                bad = (result != expected).nonzero()[0].item()
                raise AssertionError(f"rank={rank} index={bad} got={result[bad].item()} expected={expected[bad].item()}")
            log("integrity PASS")
if mode == "xccl":
    for dtype in (torch.float32, torch.float16, torch.bfloat16):
        for count in (31, 32768):
            pattern = torch.arange(count, dtype=torch.int32).remainder_(31).to(dtype)
            tensor = (pattern + rank + 1).to(f"xpu:{rank}")
            gathered = torch.empty(count * 2, dtype=dtype, device=f"xpu:{rank}")
            log(f"begin all_gather dtype={dtype} elements={count}")
            dist.all_gather_into_tensor(gathered, tensor)
            torch.xpu.synchronize()
            assert torch.equal(gathered.cpu(), torch.cat((pattern + 1, pattern + 2)))
            log("all_gather integrity PASS")
            whole = torch.cat((pattern + rank + 1, pattern + rank + 4)).to(f"xpu:{rank}")
            reduced = torch.empty_like(tensor)
            log(f"begin reduce_scatter dtype={dtype} elements={count}")
            dist.reduce_scatter_tensor(reduced, whole)
            torch.xpu.synchronize()
            assert torch.equal(reduced.cpu(), pattern * 2 + (3 if rank == 0 else 9))
            log("reduce_scatter integrity PASS")
            for root in (0, 1):
                tensor = (pattern + rank + 1).to(f"xpu:{rank}")
                log(f"begin broadcast root={root} dtype={dtype} elements={count}")
                dist.broadcast(tensor, src=root)
                torch.xpu.synchronize()
                assert torch.equal(tensor.cpu(), pattern + root + 1)
                log("broadcast integrity PASS")
log("ALL CASES PASS")
with open("/proc/self/maps") as maps:
    print("".join(line for line in maps if any(s in line for s in ("libccl", "libze_", "libsycl", "libur_"))), flush=True)
dist.destroy_process_group()
