#![deny(unsafe_code)]

//! Shared resource budgets and cancellation primitives for collector refreshes.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const WAIT_SLICE: Duration = Duration::from_millis(10);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeLimits {
    pub local_workers: usize,
    pub network_workers: usize,
    pub account_tasks: usize,
    pub response_body_bytes: usize,
}

impl Default for RuntimeLimits {
    fn default() -> Self {
        Self {
            // C110: 主源 + 次要源工作池共享本机扫描许可, 4 个许可即主源与 3 个次要源并行
            local_workers: 4,
            network_workers: 4,
            account_tasks: 4,
            response_body_bytes: 4 * 1024 * 1024,
        }
    }
}

impl RuntimeLimits {
    pub fn validate(self) -> Result<Self, RuntimeError> {
        if self.local_workers == 0
            || self.local_workers > 16
            || self.network_workers == 0
            || self.network_workers > 16
            || self.account_tasks == 0
            || self.account_tasks > 16
            || self.response_body_bytes == 0
            || self.response_body_bytes > 16 * 1024 * 1024
        {
            return Err(RuntimeError::InvalidLimits);
        }
        Ok(self)
    }

    pub fn budgets(self) -> Result<RuntimeBudgets, RuntimeError> {
        let limits = self.validate()?;
        Ok(RuntimeBudgets {
            local: PermitPool::new(limits.local_workers),
            network: PermitPool::new(limits.network_workers),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeError {
    Cancelled,
    DeadlineExceeded,
    Closed,
    InvalidLimits,
}

#[derive(Clone, Debug, Default)]
pub struct CancellationToken {
    inner: Arc<CancellationState>,
}

#[derive(Debug, Default)]
struct CancellationState {
    cancelled: AtomicBool,
    deadline: Mutex<Option<Instant>>,
}

impl CancellationToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_deadline(deadline: Instant) -> Self {
        let token = Self::new();
        *token
            .inner
            .deadline
            .lock()
            .expect("cancellation deadline mutex poisoned") = Some(deadline);
        token
    }

    pub fn cancel(&self) {
        self.inner.cancelled.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.cancelled.load(Ordering::Acquire)
    }

    pub fn check(&self) -> Result<(), RuntimeError> {
        if self.is_cancelled() {
            return Err(RuntimeError::Cancelled);
        }
        let expired = self
            .inner
            .deadline
            .lock()
            .expect("cancellation deadline mutex poisoned")
            .is_some_and(|deadline| Instant::now() >= deadline);
        if expired {
            self.cancel();
            return Err(RuntimeError::DeadlineExceeded);
        }
        Ok(())
    }
}

#[derive(Clone)]
pub struct RuntimeBudgets {
    local: PermitPool,
    network: PermitPool,
}

impl RuntimeBudgets {
    pub fn acquire_local(&self, token: &CancellationToken) -> Result<Permit, RuntimeError> {
        self.local.acquire(token)
    }

    pub fn acquire_network(&self, token: &CancellationToken) -> Result<Permit, RuntimeError> {
        self.network.acquire(token)
    }
}

#[derive(Clone)]
pub struct PermitPool {
    inner: Arc<PermitPoolInner>,
}

struct PermitPoolInner {
    state: Mutex<PermitState>,
    wake: Condvar,
}

struct PermitState {
    available: usize,
    capacity: usize,
}

impl PermitPool {
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "permit pool capacity must be positive");
        Self {
            inner: Arc::new(PermitPoolInner {
                state: Mutex::new(PermitState {
                    available: capacity,
                    capacity,
                }),
                wake: Condvar::new(),
            }),
        }
    }

    pub fn acquire(&self, token: &CancellationToken) -> Result<Permit, RuntimeError> {
        let mut state = self.inner.state.lock().expect("permit pool mutex poisoned");
        loop {
            token.check()?;
            if state.available > 0 {
                state.available -= 1;
                return Ok(Permit {
                    inner: Arc::clone(&self.inner),
                });
            }
            let (next_state, _) = self
                .inner
                .wake
                .wait_timeout(state, WAIT_SLICE)
                .expect("permit pool condvar poisoned");
            state = next_state;
        }
    }
}

pub struct Permit {
    inner: Arc<PermitPoolInner>,
}

impl Drop for Permit {
    fn drop(&mut self) {
        release_permit(&self.inner);
    }
}

fn release_permit(inner: &PermitPoolInner) {
    let mut state = inner.state.lock().expect("permit pool mutex poisoned");
    state.available = state.available.saturating_add(1).min(state.capacity);
    inner.wake.notify_one();
}

#[cfg(test)]
mod tests {
    use super::{CancellationToken, RuntimeError, RuntimeLimits};
    use std::thread;
    use std::time::{Duration, Instant};

    #[test]
    fn limits_create_bounded_resource_pools() {
        let limits = RuntimeLimits::default();
        let budgets = limits.budgets().unwrap();
        let permit = budgets.acquire_local(&CancellationToken::new()).unwrap();
        drop(permit);
        assert!(RuntimeLimits {
            local_workers: 0,
            ..limits
        }
        .validate()
        .is_err());
    }

    #[test]
    fn deadline_token_expires_without_busy_waiting() {
        let token = CancellationToken::with_deadline(Instant::now() + Duration::from_millis(1));
        thread::sleep(Duration::from_millis(5));
        assert_eq!(token.check(), Err(RuntimeError::DeadlineExceeded));
        assert!(token.is_cancelled());
    }
}
