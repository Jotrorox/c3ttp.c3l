module c3ttp @private;

import std::core::env;
import std::core::mem;
import std::os::posix;
import libc;

const uptr SYS_IO_URING_SETUP = 425;
const uptr SYS_IO_URING_ENTER = 426;
const ulong IORING_OFF_SQ_RING = 0;
const ulong IORING_OFF_CQ_RING = 0x08000000;
const ulong IORING_OFF_SQES = 0x10000000;
const uint IORING_FEAT_SINGLE_MMAP = 1;
const uint IORING_ENTER_GETEVENTS = 1;
const uint IORING_SETUP_COOP_TASKRUN = 1 << 8;
const uint IORING_SETUP_SINGLE_ISSUER = 1 << 12;

struct IoSqringOffsets @feat(LINUX)
{
	uint head;
	uint tail;
	uint ring_mask;
	uint ring_entries;
	uint flags;
	uint dropped;
	uint array;
	uint reserved;
	ulong user_addr;
}

struct IoCqringOffsets @feat(LINUX)
{
	uint head;
	uint tail;
	uint ring_mask;
	uint ring_entries;
	uint overflow;
	uint cqes;
	uint flags;
	uint reserved;
	ulong user_addr;
}

struct IoUringParams @feat(LINUX)
{
	uint sq_entries;
	uint cq_entries;
	uint flags;
	uint sq_thread_cpu;
	uint sq_thread_idle;
	uint features;
	uint wq_fd;
	uint[3] reserved;
	IoSqringOffsets sq_off;
	IoCqringOffsets cq_off;
}

// Stable 64-byte SQE prefix from linux/io_uring.h. The named fields overlap
// unions in the C ABI; these are the variants used by this server.
struct IoUringSqe @feat(LINUX)
{
	char opcode;
	char flags;
	ushort ioprio;
	int fd;
	ulong offset;
	ulong address;
	uint length;
	uint operation_flags;
	ulong user_data;
	ushort buffer_index;
	ushort personality;
	int file_index;
	ulong address3;
	ulong reserved;
}

struct IoUringCqe @feat(LINUX)
{
	ulong user_data;
	int result;
	uint flags;
}

struct IoUring @feat(LINUX)
{
	int fd;
	void* sq_mapping;
	void* cq_mapping;
	IoUringSqe* sqes;
	usz sq_mapping_size;
	usz cq_mapping_size;
	usz sqes_size;
	uint* sq_head;
	uint* sq_tail;
	uint* sq_mask;
	uint* sq_entries;
	uint* sq_array;
	uint* cq_head;
	uint* cq_tail;
	uint* cq_mask;
	IoUringCqe* cqes;
	uint pending;
	uint to_submit;
}

fn void* pointer_at(void* base, uint offset) @private @inline @feat(LINUX)
{
	return (char*)base + offset;
}

fn bool syscall_failed(iptr result) @private @inline @feat(LINUX)
{
	return result < 0;
}

fn bool uring_init(IoUring* ring, uint entries) @private @feat(LINUX)
{
	*ring = { .fd = -1 };
	IoUringParams params = {
		.flags = IORING_SETUP_COOP_TASKRUN | IORING_SETUP_SINGLE_ISSUER,
	};
	iptr setup = (iptr)@syscall(SYS_IO_URING_SETUP, (uptr)entries, (uptr)&params);
	if (syscall_failed(setup))
	{
		params = {};
		setup = (iptr)@syscall(SYS_IO_URING_SETUP, (uptr)entries, (uptr)&params);
		if (syscall_failed(setup)) return false;
	}
	ring.fd = (int)setup;
	ring.sq_mapping_size = (usz)params.sq_off.array + (usz)params.sq_entries * uint::size;
	ring.cq_mapping_size = (usz)params.cq_off.cqes + (usz)params.cq_entries * IoUringCqe::size;
	if (params.features & IORING_FEAT_SINGLE_MMAP)
	{
		ring.sq_mapping_size = max(ring.sq_mapping_size, ring.cq_mapping_size);
		ring.cq_mapping_size = ring.sq_mapping_size;
	}
	ring.sq_mapping = posix::mmap(null, ring.sq_mapping_size, posix::PROT_READ | posix::PROT_WRITE,
		posix::MAP_SHARED, ring.fd, (Off_t)IORING_OFF_SQ_RING);
	if (ring.sq_mapping == posix::MAP_FAILED) { (void)libc::close(ring.fd); return false; }
	if (params.features & IORING_FEAT_SINGLE_MMAP)
	{
		ring.cq_mapping = ring.sq_mapping;
	}
	else
	{
		ring.cq_mapping = posix::mmap(null, ring.cq_mapping_size, posix::PROT_READ | posix::PROT_WRITE,
			posix::MAP_SHARED, ring.fd, (Off_t)IORING_OFF_CQ_RING);
		if (ring.cq_mapping == posix::MAP_FAILED)
		{
			(void)posix::munmap(ring.sq_mapping, ring.sq_mapping_size);
			(void)libc::close(ring.fd);
			return false;
		}
	}
	ring.sqes_size = (usz)params.sq_entries * IoUringSqe::size;
	ring.sqes = posix::mmap(null, ring.sqes_size, posix::PROT_READ | posix::PROT_WRITE,
		posix::MAP_SHARED, ring.fd, (Off_t)IORING_OFF_SQES);
	if ((void*)ring.sqes == posix::MAP_FAILED)
	{
		if (ring.cq_mapping != ring.sq_mapping) (void)posix::munmap(ring.cq_mapping, ring.cq_mapping_size);
		(void)posix::munmap(ring.sq_mapping, ring.sq_mapping_size);
		(void)libc::close(ring.fd);
		return false;
	}
	ring.sq_head = pointer_at(ring.sq_mapping, params.sq_off.head);
	ring.sq_tail = pointer_at(ring.sq_mapping, params.sq_off.tail);
	ring.sq_mask = pointer_at(ring.sq_mapping, params.sq_off.ring_mask);
	ring.sq_entries = pointer_at(ring.sq_mapping, params.sq_off.ring_entries);
	ring.sq_array = pointer_at(ring.sq_mapping, params.sq_off.array);
	ring.cq_head = pointer_at(ring.cq_mapping, params.cq_off.head);
	ring.cq_tail = pointer_at(ring.cq_mapping, params.cq_off.tail);
	ring.cq_mask = pointer_at(ring.cq_mapping, params.cq_off.ring_mask);
	ring.cqes = pointer_at(ring.cq_mapping, params.cq_off.cqes);
	return true;
}

fn void uring_destroy(IoUring* ring) @private @feat(LINUX)
{
	if (ring.fd < 0) return;
	(void)posix::munmap(ring.sqes, ring.sqes_size);
	if (ring.cq_mapping != ring.sq_mapping) (void)posix::munmap(ring.cq_mapping, ring.cq_mapping_size);
	(void)posix::munmap(ring.sq_mapping, ring.sq_mapping_size);
	(void)libc::close(ring.fd);
	*ring = { .fd = -1 };
}

fn IoUringSqe* uring_get_sqe(IoUring* ring) @private @feat(LINUX)
{
	uint head = mem::@atomic_load(*ring.sq_head, ACQUIRE);
	uint tail = mem::@atomic_load(*ring.sq_tail, RELAXED) + ring.pending;
	uint entries = mem::@atomic_load(*ring.sq_entries, RELAXED);
	if (tail - head >= entries) return null;
	uint index = tail & mem::@atomic_load(*ring.sq_mask, RELAXED);
	IoUringSqe* sqe = &ring.sqes[index];
	*sqe = {};
	ring.sq_array[index] = index;
	ring.pending++;
	return sqe;
}

fn int uring_submit(IoUring* ring, uint minimum_completions) @private @feat(LINUX)
{
	uint pending = ring.pending;
	if (pending)
	{
		uint tail = mem::@atomic_load(*ring.sq_tail, RELAXED);
		mem::@atomic_store(*ring.sq_tail, tail + pending, RELEASE);
		ring.pending = 0;
		ring.to_submit += pending;
	}
	uint flags = minimum_completions ? IORING_ENTER_GETEVENTS : 0;
	iptr result = (iptr)@syscall(SYS_IO_URING_ENTER, (uptr)ring.fd, (uptr)ring.to_submit,
		(uptr)minimum_completions, (uptr)flags, (uptr)0, (uptr)0);
	if (syscall_failed(result)) return (int)result;
	uint submitted = (uint)result;
	ring.to_submit -= min(submitted, ring.to_submit);
	return (int)result;
}

fn bool uring_submit_retry(IoUring* ring, uint minimum_completions) @private @feat(LINUX)
{
	while (true)
	{
		int result = uring_submit(ring, minimum_completions);
		if (result >= 0) return true;
		if (result != -4) return false; // -EINTR from the raw Linux syscall ABI.
	}
}

fn uint uring_ready(IoUring* ring) @private @inline @feat(LINUX)
{
	return mem::@atomic_load(*ring.cq_tail, ACQUIRE) - mem::@atomic_load(*ring.cq_head, RELAXED);
}

fn IoUringCqe* uring_cqe(IoUring* ring, uint offset) @private @inline @feat(LINUX)
{
	uint head = mem::@atomic_load(*ring.cq_head, RELAXED);
	return &ring.cqes[(head + offset) & mem::@atomic_load(*ring.cq_mask, RELAXED)];
}

fn void uring_advance(IoUring* ring, uint count) @private @inline @feat(LINUX)
{
	uint head = mem::@atomic_load(*ring.cq_head, RELAXED);
	mem::@atomic_store(*ring.cq_head, head + count, RELEASE);
}

fn bool io_uring_available_impl() @private
{
	$if env::LINUX:
		IoUring ring;
		if (!uring_init(&ring, 2)) return false;
		uring_destroy(&ring);
		return true;
	$else
		return false;
	$endif
}
