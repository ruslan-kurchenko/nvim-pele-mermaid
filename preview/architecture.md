# Architecture

This service accepts jobs.
The API and workers run independently.

## Request flow

```mermaid
graph LR
  A[Client] --> B[API]
  B --> C[Queue]
```

The API returns before the job completes.

## Worker lifecycle

```mermaid
graph LR
  A[Queued] --> B[Running]
  B --> C[Done]
```

Retry failed jobs without losing input.
