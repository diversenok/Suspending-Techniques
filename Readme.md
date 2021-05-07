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
3. *How might someone bypass them?*

# Tools

I wrote several tools that you can use to experiment and reproduce my observations:

 - **Suspend Tool** is a program that can suspend/freeze processes using several different methods. I will cover the techniques it implements in the next section.
 - **Mode Transition Monitor** is a program that detects all kernel-to-user mode transitions happening within a specific process. It achieves this by installing the Instrumentation Callback (see [slides by Alex Ionescu](https://github.com/ionescu007/HookingNirvana/blob/9e4e8e326b9dfd10a7410986486e567e5980f913/Esoteric%20Hooks.pdf) and a [blog post by Antonio Cocomazzi](https://splintercod3.blogspot.com/p/weaponizing-mapping-injection-with.html)) and counting its invocations.
 - **Inject Test Tool** is a program for injecting dummy threads (either directly or via a thread pool) into a process.
 - **SuspendMe** is a test application that demonstrates several approaches for bypassing suspension.

# Techniques

## Snapshot & Suspend Threads (Not Covered)

It appears that the documented way to suspend a process is to snapshot the list of its threads via [CreateToolhelp32Snapshot](https://docs.microsoft.com/en-us/windows/win32/api/tlhelp32/nf-tlhelp32-createtoolhelp32snapshot) and then suspend each one of them using [SuspendThread](https://docs.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-suspendthread). This approach sounds like a terrible idea for several reasons:

1. It requires passing access checks on all target threads when obtaining their handles.
2. This method is full of inherent race conditions. It (**A**) suspends threads one-by-one, (**B**) does not detect their creation (that can happen between snapshotting and completing suspension), and (**C**) does not detect their termination. The last part implies a relatively small but non-zero chance to suspend a thread in a completely unrelated process if the original one terminates and its ID gets reused within a short time.
3. The documented function for making process/thread snapshots introduces a significant overhead compared to its native counterpart.
4. It requires the caller to have at least medium integrity for snapshotting. Which is, to be fair, rarely an issue.

## Enumerate & Suspend Threads

### Idea
We can improve the previous approach by replacing snapshotting with a loop of [NtGetNextThread](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntpsapi.h#L1253-L1263)'s. The result is still somewhat discouraging because of items **1** and **2A**, but at least it resolves **2B**, **2C**, **3**, and **4** from the list above. NtGetNextThread does iterate through the threads created after the enumeration started, so item **2B** does not apply. Additionally, using handles instead of Thread IDs prevents the most destructive scenario **2C**.

### Bypasses
Aside from protecting objects with security descriptors that deny specific actions, a program can also exploit the race condition that appears because we don't perform suspension as an atomic operation. The code in the target process runs concurrently with our algorithm, so if it manages to resume at least one thread before we complete their enumeration, it wins. The **SuspendMe** tool includes this functionality as one of the options. The implementation for it is straightforward: just several threads resuming each other in a tight loop. You might find it surprising, but the tool counteracts suspension quite effectively, especially on multi-processor systems.

Additionally, this method does not account for the future threads that might appear in the process while it's suspended. I know at least two scenarios of when it can happen. First of all, thread pools. They allow a variable number of threads to balance the load when dealing with a set of tasks. Every process on Windows includes at least one of them because of the module loader in ntdll, but other components use the infrastructure they provide as well. If the system notices that a thread pool cannot keep up with the upcoming tasks (of course, we are suspended!), it might create additional threads to help us with it. It already lifts suspension on the scale of the process (by definition), but a specially crafted program can take advantage of its thread pools to resume itself. You can experiment with this idea with a pair of tools: select an option for creating a thread pool in **SuspendMe**, and then use **InjectTool** to adjust the minimum number of threads, triggering their creation.

Secondly, some external tools can create threads to execute code within the process's context. Most of the time, it requires explicit user action (for example, when injecting DLLs) but can also happen unexpectedly. **Process Explorer**, for example, uses thread injection to retrieve debugging information when the user merely navigates to the threads page in the process's properties. Someone might argue that the thread exists temporarily and only executes predefined code, but, again, a specially crafted application can take advantage of it. **SuspendMe** includes a pair of options that patch `RtlUserThreadStart` - a function from ntdll where almost any thread starts - and hijack its execution, resuming the process. You can try the following sequence with [Process Explorer](https://docs.microsoft.com/en-us/sysinternals/downloads/process-explorer): 

1. Start **SuspendMe** and select the corresponding option for patching.
2. Suspend the process via the context menu in the process list. You will see that that it was indeed suspended.
3. Double-click it to inspect the properties, switch to the Threads page.
4. **SuspendMe** should hijack the thread and resume itself.

In the next section, we will discuss how it is possible despite **Process Explorer** using a different suspension technique. Fortunately, this behavior does not apply to **Process Hacker**.

### Overview
Pros                                                        | Cons
----------------------------------------------------------- | ----
Does not require keeping any handles to maintain suspension | Requires passing access checks on threads
_-_                                                         | Does not prevent race conditions
_-_                                                         | Does not suspend future threads

