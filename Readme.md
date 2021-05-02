# Suspending-Techniques

This is a repository that includes several tools for experimenting with various techniques for suspending processes on Windows. The idea of this project arose from a [discussion at Process Hacker](https://github.com/processhacker/processhacker/issues/856).

# Idea

While we can [argue on the exact definition](https://github.com/processhacker/processhacker/issues/856#issuecomment-813092041) of what it means for a thread to be in a suspended state, conceptually, it requires trapping it in the kernel mode and, therefore, preventing it from executing any user-mode code. Since processes do not execute code anyway (they are merely containers for resources), we refer to them as being suspended when all of their threads are. What is interesting for us is to control suspension from an external tool such as Process Hacker.

Under the hood, the system maintains a ***suspend count*** for each thread (stored in `KTHREAD`), which you can increment and decrement through [SuspendThread](https://docs.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-suspendthread) and [ResumeThread](https://docs.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-resumethread), respectively. Besides that, suspending queues a kernel APC that always executes before the thread switches modes. Thus, a thread can never execute user-mode code unless its suspend count is zero. Check out [this comment](https://github.com/microsoft/terminal/issues/9704#issuecomment-814398869) for some interesting insights on the pitfalls of interoperation between suspension and non-alertable synchronous I/O.

The second mechanism we are going to cover here is called ***freezing***. Overall, it acts similar to suspension but cannot be undone via ResumeThread. Remember that suspension is an entirely per-thread feature? Freezing, on the other hand, is somewhat hybrid. Each thread stores a dedicated bit within its `KTHREAD` structure (as part of `ThreadFlags`), but the actual counter resides in the process object (`KPROCESS`).

[NtQueryInformationThread](https://github.com/processhacker/processhacker/blob/000a748b3c2bf75cff03212cbc59a30cd67c2043/phnt/include/ntpsapi.h#L1360-L1369) exposes the value of the suspend counter via the ThreadSuspendCount info class. Note that the function increments the output (originating from `KTHREAD`'s `SuspendCount`) by one for frozen processes. So, if you ever encounter a thread with a ThreadSuspendCount of one that you can increment but cannot decrement - it is definitely frozen.

Finally, there is ***deep freezing***. This feature is built on top of ordinary freezing using a special per-process flag that indicates that newly created threads must be immediately frozen.

If you want to know more technical details about these mechanisms, check out `PsSuspendThread` and `PsFreezeProcess` in ntoskrnl, and read the chapter about threads in [Windows Internals](https://books.google.nl/books?id=V4kjnwEACAAJ).

# Research Questions

1. *What are the available options that allow suspending or freezing other processes?*
2. *What are their benefits and shortcomings?*
3. *How someone might bypass them?*

