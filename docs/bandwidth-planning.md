# VPS Bandwidth Planning

## Vultr Plan

- **Instance:** `vc2-1c-1gb` (1 vCPU, 1GB RAM, 25GB SSD)
- **Included bandwidth:** 1TB/month
- **Overage:** $0.01/GB beyond 1TB

## Estimated Monthly Usage

| Service | Estimate | Notes |
|---------|----------|-------|
| Plex streaming | ~170 GB | Based on typical usage patterns |
| Valheim game server | <1 GB | Small UDP packets, negligible |
| Mobile WireGuard | <1 GB | Occasional mobile browsing |
| **Total** | **~172 GB** | Well within 1TB limit |

## Monitoring

- Check the Vultr dashboard monthly for actual bandwidth usage
- Vultr sends email alerts at 80% and 100% of bandwidth allocation
- Optionally, scrape the Vultr API with Prometheus for automated monitoring
