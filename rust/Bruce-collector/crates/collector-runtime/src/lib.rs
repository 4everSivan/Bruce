#![deny(unsafe_code)]

//! Shared resource budgets and cancellation primitives for collector refreshes.

use std::collections::{HashMap, VecDeque};
use std::hash::Hash;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const WAIT_SLICE: Duration = Duration::from_millis(10);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeLimits {
    pub local_workers: usize,
    pub network_workers: usize,
    pub sqlite_readers: usize,
    pub account_tasks: usize,
    pub response_body_bytes: usize,
    pub aggregate_queue_capacity: usize,
    pub sqlite_batch_rows: usize,
    pub sqlite_max_rows: usize,
}

impl Default for RuntimeLimits {
    fn default() -> Self {
        Self {
            local_workers: 2,
            network_workers: 4,
            sqlite_readers: 2,
            account_tasks: 4,
            response_body_bytes: 4 * 1024 * 1024,
            aggregate_queue_capacity: 1_024,
            sqlite_batch_rows: 256,
            sqlite_max_rows: 10_000,
        }
    }
}

impl RuntimeLimits {
    pub fn validate(self) -> Result<Self, RuntimeError> {
        if self.local_workers == 0
            || self.local_workers > 16
            || self.network_workers == 0
            || self.network_workers > 16
            || self.sqlite_readers == 0
            || self.sqlite_readers > 8
            || self.account_tasks == 0
            || self.account_tasks > 16
            || self.response_body_bytes == 0
            || self.response_body_bytes > 16 * 1024 * 1024
            || self.aggregate_queue_capacity == 0
            || self.aggregate_queue_capacity > 100_000
            || self.sqlite_batch_rows == 0
            || self.sqlite_batch_rows > 1_024
            || self.sqlite_max_rows == 0
            || self.sqlite_max_rows > 100_000
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
            sqlite: PermitPool::new(limits.sqlite_readers),
            account: PermitPool::new(limits.account_tasks),
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
    sqlite: PermitPool,
    account: PermitPool,
}

impl RuntimeBudgets {
    pub fn acquire_local(&self, token: &CancellationToken) -> Result<Permit, RuntimeError> {
        self.local.acquire(token)
    }

    pub fn acquire_network(&self, token: &CancellationToken) -> Result<Permit, RuntimeError> {
        self.network.acquire(token)
    }

    pub fn acquire_sqlite(&self, token: &CancellationToken) -> Result<Permit, RuntimeError> {
        self.sqlite.acquire(token)
    }

    pub fn acquire_account(&self, token: &CancellationToken) -> Result<Permit, RuntimeError> {
        self.account.acquire(token)
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
                    released: false,
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

    pub fn capacity(&self) -> usize {
        self.inner
            .state
            .lock()
            .expect("permit pool mutex poisoned")
            .capacity
    }

    pub fn available(&self) -> usize {
        self.inner
            .state
            .lock()
            .expect("permit pool mutex poisoned")
            .available
    }
}

pub struct Permit {
    inner: Arc<PermitPoolInner>,
    released: bool,
}

impl Permit {
    pub fn release(mut self) {
        self.released = true;
        release_permit(&self.inner);
    }
}

impl Drop for Permit {
    fn drop(&mut self) {
        if !self.released {
            release_permit(&self.inner);
            self.released = true;
        }
    }
}

fn release_permit(inner: &PermitPoolInner) {
    let mut state = inner.state.lock().expect("permit pool mutex poisoned");
    state.available = state.available.saturating_add(1).min(state.capacity);
    inner.wake.notify_one();
}

pub struct BoundedQueue<T> {
    state: Mutex<QueueState<T>>,
    not_empty: Condvar,
    not_full: Condvar,
}

struct QueueState<T> {
    items: VecDeque<T>,
    capacity: usize,
    closed: bool,
}

impl<T> BoundedQueue<T> {
    pub fn new(capacity: usize) -> Result<Self, RuntimeError> {
        if capacity == 0 {
            return Err(RuntimeError::InvalidLimits);
        }
        Ok(Self {
            state: Mutex::new(QueueState {
                items: VecDeque::with_capacity(capacity.min(4_096)),
                capacity,
                closed: false,
            }),
            not_empty: Condvar::new(),
            not_full: Condvar::new(),
        })
    }

    pub fn push(&self, item: T, token: &CancellationToken) -> Result<(), RuntimeError> {
        let mut state = self.state.lock().expect("bounded queue mutex poisoned");
        loop {
            token.check()?;
            if state.closed {
                return Err(RuntimeError::Closed);
            }
            if state.items.len() < state.capacity {
                state.items.push_back(item);
                self.not_empty.notify_one();
                return Ok(());
            }
            let (next_state, _) = self
                .not_full
                .wait_timeout(state, WAIT_SLICE)
                .expect("bounded queue condvar poisoned");
            state = next_state;
        }
    }

    pub fn pop(&self, token: &CancellationToken) -> Result<Option<T>, RuntimeError> {
        let mut state = self.state.lock().expect("bounded queue mutex poisoned");
        loop {
            token.check()?;
            if let Some(item) = state.items.pop_front() {
                self.not_full.notify_one();
                return Ok(Some(item));
            }
            if state.closed {
                return Ok(None);
            }
            let (next_state, _) = self
                .not_empty
                .wait_timeout(state, WAIT_SLICE)
                .expect("bounded queue condvar poisoned");
            state = next_state;
        }
    }

    pub fn close(&self) {
        let mut state = self.state.lock().expect("bounded queue mutex poisoned");
        state.closed = true;
        self.not_empty.notify_all();
        self.not_full.notify_all();
    }

    pub fn len(&self) -> usize {
        self.state
            .lock()
            .expect("bounded queue mutex poisoned")
            .items
            .len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn capacity(&self) -> usize {
        self.state
            .lock()
            .expect("bounded queue mutex poisoned")
            .capacity
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SingleFlightError<E> {
    Cancelled,
    Failed(E),
}

struct Flight<V, E> {
    state: Mutex<FlightState<V, E>>,
    wake: Condvar,
}

struct FlightState<V, E> {
    started: bool,
    result: Option<Result<Arc<V>, E>>,
}

pub struct AccountSingleFlight<K, V, E> {
    flights: Mutex<HashMap<K, Arc<Flight<V, E>>>>,
}

impl<K, V, E> Default for AccountSingleFlight<K, V, E> {
    fn default() -> Self {
        Self {
            flights: Mutex::new(HashMap::new()),
        }
    }
}

impl<K, V, E> AccountSingleFlight<K, V, E>
where
    K: Eq + Hash + Clone,
    V: Send + Sync + 'static,
    E: Clone + Send + Sync + 'static,
{
    pub fn run<F>(
        &self,
        key: K,
        token: &CancellationToken,
        operation: F,
    ) -> Result<Arc<V>, SingleFlightError<E>>
    where
        F: FnOnce() -> Result<V, E>,
    {
        let flight = {
            let mut flights = self.flights.lock().expect("single-flight mutex poisoned");
            flights
                .entry(key.clone())
                .or_insert_with(|| {
                    Arc::new(Flight {
                        state: Mutex::new(FlightState {
                            started: false,
                            result: None,
                        }),
                        wake: Condvar::new(),
                    })
                })
                .clone()
        };
        let leader = {
            let mut state = flight.state.lock().expect("single-flight mutex poisoned");
            if state.started {
                false
            } else {
                state.started = true;
                true
            }
        };
        if leader {
            let result = operation().map(Arc::new);
            let returned = result.clone().map_err(SingleFlightError::Failed);
            {
                let mut state = flight.state.lock().expect("single-flight mutex poisoned");
                state.result = Some(result);
                flight.wake.notify_all();
            }
            let mut flights = self.flights.lock().expect("single-flight mutex poisoned");
            if flights
                .get(&key)
                .is_some_and(|current| Arc::ptr_eq(current, &flight))
            {
                flights.remove(&key);
            }
            return returned;
        }

        let mut state = flight.state.lock().expect("single-flight mutex poisoned");
        loop {
            token.check().map_err(|error| match error {
                RuntimeError::Cancelled | RuntimeError::DeadlineExceeded => {
                    SingleFlightError::Cancelled
                }
                RuntimeError::Closed | RuntimeError::InvalidLimits => SingleFlightError::Cancelled,
            })?;
            if let Some(result) = &state.result {
                return result.clone().map_err(SingleFlightError::Failed);
            }
            let (next_state, _) = flight
                .wake
                .wait_timeout(state, WAIT_SLICE)
                .expect("single-flight condvar poisoned");
            state = next_state;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        AccountSingleFlight, BoundedQueue, CancellationToken, RuntimeError, RuntimeLimits,
        SingleFlightError,
    };
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Barrier};
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
    fn queue_applies_capacity_and_cancellation_backpressure() {
        let queue = BoundedQueue::new(1).unwrap();
        let token = CancellationToken::new();
        queue.push(1, &token).unwrap();
        let cancelled = token.clone();
        let queue_for_thread = Arc::new(queue);
        let queue_for_thread_clone = Arc::clone(&queue_for_thread);
        let handle = thread::spawn(move || queue_for_thread_clone.push(2, &cancelled));
        thread::sleep(Duration::from_millis(20));
        token.cancel();
        assert_eq!(handle.join().unwrap(), Err(RuntimeError::Cancelled));
        assert_eq!(
            queue_for_thread.pop(&CancellationToken::new()).unwrap(),
            Some(1)
        );
        queue_for_thread.close();
        assert_eq!(
            queue_for_thread.pop(&CancellationToken::new()).unwrap(),
            None
        );
    }

    #[test]
    fn same_account_runs_once_and_shares_result() {
        let flights = Arc::new(AccountSingleFlight::<String, usize, String>::default());
        let calls = Arc::new(AtomicUsize::new(0));
        let barrier = Arc::new(Barrier::new(8));
        let mut handles = Vec::new();
        for _ in 0..8 {
            let flights = Arc::clone(&flights);
            let calls = Arc::clone(&calls);
            let barrier = Arc::clone(&barrier);
            handles.push(thread::spawn(move || {
                barrier.wait();
                flights
                    .run("account-a".to_owned(), &CancellationToken::new(), || {
                        calls.fetch_add(1, Ordering::AcqRel);
                        thread::sleep(Duration::from_millis(20));
                        Ok::<_, String>(42)
                    })
                    .unwrap()
            }));
        }
        for handle in handles {
            assert_eq!(*handle.join().unwrap(), 42);
        }
        assert_eq!(calls.load(Ordering::Acquire), 1);
    }

    #[test]
    fn deadline_token_expires_without_busy_waiting() {
        let token = CancellationToken::with_deadline(Instant::now() + Duration::from_millis(1));
        thread::sleep(Duration::from_millis(5));
        assert_eq!(token.check(), Err(RuntimeError::DeadlineExceeded));
        assert!(token.is_cancelled());
        let _ = SingleFlightError::<String>::Cancelled;
    }
}
