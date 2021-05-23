# Suspending-Techniques

This is a repository that includes several tools for experimenting with various techniques for suspending processes on Windows. The idea of this project arose from a [discussion at Process Hacker](https://github.com/processhacker/processhacker/issues/856).

I performed most experiments on Windows 10 20H2, but the topics I describe here apply at least starting from Windows 7 (except for the functionality that did not exist yet). If you are using Windows Insider builds, see the notes below the next section because there are some changes in the behavior.

# Idea

While we can [argue on the exact definition](https://github.com/processhacker/processhacker/issues/856#issuecomment-813092041) of what it means for a thread to be in a suspended state, conceptually, it requires trapping it in the kernel mode and, therefore, preventing it from executing any user-mode code. Since processes do not execute code anyway (they are merely containers for resources), we refer to them as being suspended when all their threads are. What is interesting for us is to control suspension from an external tool such as Process Hacker.

Under the hood, the system maintains a ***suspend count*** for each thread (stored in `KTHREAD`), which we can increment and decrement through [`SuspendThread`](https://docs.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-suspendthread) and [`ResumeThread`](https://docs.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-resumethread), respectively. Besides that, suspending queues a kernel APC that always executes before the thread switches modes. Thus, a thread can never execute user-mode code unless its suspend count is zero. Check out [this comment](https://github.com/microsoft/terminal/issues/9704#issuecomment-814398869) for some interesting insights on the pitfalls of interoperation between suspension and non-alertable synchronous I/O.

The second mechanism we are going to cover here is called ***freezing***. Overall, it acts like suspension but cannot be undone via `ResumeThread`. Remember that suspension is an entirely per-thread feature? Freezing, on the other hand, is somewhat hybrid. Each thread stores a dedicated bit within its `KTHREAD` structure (as part of `ThreadFlags`), but the actual counter resides in the process object (`KPROCESS`).

[`NtQueryInformationThread`](https://github.com/processhacker/processhacker/blob/000a748b3c2bf75cff03212cbc59a30cd67c2043/phnt/include/ntpsapi.h#L1360-L1369) exposes the value of the suspend counter via the `ThreadSuspendCount` info class. Note that the function increments the output (originating from `KTHREAD`'s `SuspendCount`) by one for frozen processes. So, if we ever encounter a thread with a `ThreadSuspendCount` of one that we can increment but cannot decrement - it is definitely frozen.

Finally, starting from Windows 8, there is ***deep freezing***, a completely per-process concept controlled by a dedicated flag in the `KPROCESS` structure. Unlike ordinary freezing, it guarantees that new threads created in a deep-frozen process immediately become frozen as well. This feature proves to be the most reliable option when it comes to preventing code execution.

Interestingly, Microsoft recently introduced some changes to these mechanisms that made freezing and deep freezing indistinguishable, as far as my user-mode experiments can tell. It happened somewhere between Insider builds 20231 and 21286. If you are using Windows Insider, you'll notice that injecting threads into a frozen process freezes them as if the process is actually deep-frozen. While it yields some of the demonstrations I prepared less exciting, it does make multiple techniques more reliable.

If you want to know more technical details regarding these mechanisms, check out `PsSuspendThread` and `PsFreezeProcess` with their cross-references in ntoskrnl, and read [Windows Internals](https://books.google.nl/books?id=V4kjnwEACAAJ).

# Research Questions

1. *What are the available options that allow suspending or freezing other processes?*
2. *What are their benefits and shortcomings?*
3. *How might someone bypass them?*

# Tools Overview

*For more details, navigate to the [corresponding section](#tools). To download the tools, see the [releases page](https://github.com/diversenok/Suspending-Techniques/releases).*

I wrote several tools that we can use to experiment and reproduce my observations:

 - **SuspendTool** is a program that can suspend/freeze processes using several different methods. I will cover the techniques it implements in the next section.
 - **ModeTransitionMonitor** is a program that detects all kernel-to-user mode transitions happening within a specific process. If you are interested in how it works, check out the [dedicated section](#modetransitionmonitor).
 - **SuspendInfo** is a small tool that queries the state of suspension and freezing.
 - **InjectTool** is a program for injecting dummy threads (either directly or via a thread pool) into a process.
 - **SuspendMe** is a test application that demonstrates several approaches for bypassing suspension.

# Techniques

 - [Snapshot & Suspend Threads (Not Covered)](#snapshot--suspend-threads-not-covered)
 - [Enumerate & Suspend Threads](#enumerate--suspend-threads)
 - [Suspend via NtSuspendProcess](#suspend-via-ntsuspendprocess)
 - [Suspend via a Debug Object](#suspend-via-a-debug-object)
 - [Freeze via a Debug Object with Thread Injection](#freeze-via-a-debug-object-with-thread-injection)
 - [Freezing via a Job Object](#freezing-via-a-job-object)
 - [Freezing via a State Change Object](#freezing-via-a-state-change-object)

## Snapshot & Suspend Threads (Not Covered)

### Idea
It appears that the documented way to suspend a process is to snapshot the list of its threads via [`CreateToolhelp32Snapshot`](https://docs.microsoft.com/en-us/windows/win32/api/tlhelp32/nf-tlhelp32-createtoolhelp32snapshot) and then suspend each one of them using [`SuspendThread`](https://docs.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-suspendthread). This approach sounds like a terrible idea for several reasons:

1. It requires passing access checks on all target threads when obtaining their handles.
2. This method is full of inherent race conditions. It (**A**) suspends threads one-by-one, (**B**) does not detect their creation (that can happen between snapshotting and completing suspension), and (**C**) does not detect their termination. The last part implies a relatively small but non-zero chance to suspend a thread in a completely unrelated process if the original one terminates and its ID gets reused within a short time.
3. The documented function for making process/thread snapshots introduces a significant overhead compared to its native counterpart.
4. It requires the caller to have at least medium integrity for snapshotting. Which is, to be fair, rarely an issue.

## Enumerate & Suspend Threads

### Idea
We can improve the previous approach by replacing snapshotting with a loop of [`NtGetNextThread`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntpsapi.h#L1253-L1263)'s. The result is still somewhat discouraging because of items **1** and **2A**, but at least it resolves **2B**, **2C**, **3**, and **4** from the list above. `NtGetNextThread` does iterate through the threads created after the enumeration started, so item **2B** does not apply. Additionally, using handles instead of Thread IDs prevents the most destructive scenario **2C**.

### Bypasses
Aside from protecting objects with security descriptors that deny specific actions, a program can also exploit the race condition that appears because we don't perform suspension as an atomic operation. The code in the target process runs concurrently with our algorithm, so if it manages to resume at least one thread before we complete their enumeration, it wins. The **SuspendMe** tool includes this functionality as one of the options. The implementation for it is straightforward: just several threads resuming each other in a tight loop. You might find it surprising, but the tool counteracts suspension quite effectively, especially on multi-processor systems.

Additionally, this method does not account for the future threads that might appear in the process while it's suspended. I know at least two scenarios of when it can happen. First of all, thread pools. They allow a variable number of threads to balance the load when dealing with a set of tasks. Every process on Windows includes at least one of them because of the module loader in ntdll, but other components use the infrastructure they provide as well. If the system notices that a thread pool cannot keep up with the upcoming tasks (of course, we are suspended!), it might create additional threads to help us. It already lifts suspension on the scale of the process (by definition), but a specially crafted program can take advantage of its thread pools to resume itself. You can experiment with this idea with a pair of tools: select an option for creating a thread pool in **SuspendMe**, and then use **InjectTool** to adjust the minimum number of threads, triggering their creation.

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

## Suspend via NtSuspendProcess

### Idea
A pair of functions called [`NtSuspendProcess`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntpsapi.h#L1195-L1200) and [`NtResumeProcess`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntpsapi.h#L1202-L1207) provides an exceptionally straightforward and easy-to-use solution. This is the most widely used method that powers suspension functionality in **Windows Resource Monitor**, **Process Explorer**, **Process Hacker**, and a handful of other tools.

### Bypasses
Unfortunately for us, it also suffers from almost the same set of problems. The method itself is surprisingly similar to the previous one with a single significant difference - it executes in the kernel mode and does not require passing additional access checks. Essentially, it uses a loop of `PsGetNextProcessThread` + `PsSuspendThread` as opposed to `NtGetNextThread` + `NtSuspendThread` we had in the previous case. Thus, it fails to provide atomicity and falls victim to the race condition from item **2A**. And again, you can demonstrate this behavior with any of the tools mentioned above by trying to suspend the **SuspendMe** program when it works in the race-condition-bypassing mode. The examples with thread pools and thread hijacking also apply here; feel free to experiment yourself.

### Overview
Pros                                                        | Cons
----------------------------------------------------------- | ----
Does not require keeping any handles to maintain suspension | Does not prevent race conditions
_-_                                                         | Does not suspend future threads

## Suspend via a Debug Object

### Idea
How about taking an alternative path? Debugging is essentially a fancy inter-process synchronization mechanism compatible with any application out-of-the-box. If you are not familiar with its internals, here is a quick recap. First, a debugger creates a debug object (aka debug port) and then attaches it to the target process. Starting from this point, every time an event of interest occurs in the target process (be it thread creation, exception, or a breakpoint hit), the system pauses its execution and posts a message to the debug port, waiting for an acknowledgment. Additionally, attaching itself generates a process creation and a few module loading events. Luckily for us, the system does not enforce any time constraints on the responses, so we can delay them indefinitely, keeping the target paused.

In terms of Native API, we call [`NtCreateDebugObject`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntdbg.h#L231-L239), followed by [`NtDebugActiveProcess`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntdbg.h#L241-L247) (which requires `PROCESS_SUSPEND_RESUME` access to the process). Typically, debuggers implement a loop of [`NtWaitForDebugEvent`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntdbg.h#L277-L285) plus [`NtDebugContinue`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntdbg.h#L249-L256), but we don't need that since we are not interested in debugging per se. Instead, we wait until it's time to resume the process and either close the debug object or call [`NtRemoveProcessDebug`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntdbg.h#L258-L264) to detach altogether. As you can see, this method has a slight disadvantage: it requires keeping a handle to the debug object. Closing it resumes the target automatically unless we explicitly configure the kill-on-close flag that will terminate it instead. If we want to keep the process suspended after the debugger exits, we can, however, store this handle within the target process.

Interestingly, while malicious programs often implement various anti-debugging techniques, almost none of them interfere with our approach because we don't let the application execute any code. Still, a process can have only a single debug port, so if it manages to attach one to itself, it will prevent us from doing the same. I implemented an option for starting a self-debugging session in the **SuspendMe** tool but, to be honest, I did it mainly because I find it a peculiar challenge rather than a demonstration of a plausible attack vector.

### Bypasses
I was deliberately avoiding the question of whether this technique provides suspension, freezing, or deep freezing. Confusingly, it has the properties of all of them. I believe the best way to explain it is to let you experiment with the tools yourself. We'll need **SuspendTool** with option #4, **InjectTool**, all techniques from **SuspendMe**, and, optionally, **ModeTransitionMonitor** with **SuspendInfo**. You should be able to reproduce the following results:

1. There is still a race condition with suspension.
2. Creating and terminating threads freezes the process.
3. However, it does not occur when using the *hide-from-debugger* flag.
4. Yet, existing threads with this flag can get frozen.

*Note that item #3 does not apply to recent Insider builds.*

The functionality of hiding threads from debuggers is not exposed through the documented API, so the last two observations are somewhat exotic. To create such a thread, supply `THREAD_CREATE_FLAGS_HIDE_FROM_DEBUGGER` to [`NtCreateThreadEx`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntpsapi.h#L1831-L1846); to hide an existing one, use `ThreadHideFromDebugger` info class with [`NtSetInformationThread`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntpsapi.h#L1371-L1379).

As you can see, there is something sophisticated going on. Fortunately, with some knowledge about the internals of debugging, we can break it down and explain based on several simple rules:

1. Process creation and module loading events (that we receive while attaching) merely suspend the process. This suspension is subject to race conditions because, for some reason, it does not involve freezing.
2. Thread-creation and termination events, on the other hand, do a way better job: they freeze all existing threads. Technically, it is still ordinary freezing. But since it uses such convenient triggers, it is almost as good as deep freezing.
3. Hidden threads do not trigger debugging events, so they are free to execute even in a frozen process, but only if created after the freezing occurred.

*Again, note that item #3 does not apply to recent Insider builds.*

### Overview
Pros                   | Cons
---------------------- | ----
Freezes future threads | Requires keeping a handle open 
_-_                    | Does not prevent race conditions

## Freeze via a Debug Object with Thread Injection

### Idea
So, if the thread creation event is so helpful, why don't we generate one ourselves? We can inject and immediately terminate a dummy suspended thread to freeze the target. Technically, we can even avoid opening the target for `PROCESS_CREATE_THREAD` access because the kernel gives us a full-access handle after we acknowledge the process creation notification. Additionally, we can include a few other improvements, such as protecting the debug object (so nobody can detach it) and blocking remote thread creation (to mitigate the impact of injected hidden threads).

Yes, Process Explorer does hide the threads it injects from debuggers but also appears to be the only tool I know that does that. So, unless you are running Insider Preview builds, a program might exploit them to execute arbitrary code from a frozen process. I noticed that creating remote threads from user mode always looks up at the first page of the process's image (the one with the MZ header), so protecting it for the duration of suspension does the trick.

### Bypasses
Finally, we are getting somewhere: there is little a program can do to bypass this technique. It successfully prevents race conditions and the thread pool-based bypass. As far as I can tell, the only options that still might work are the following:

1. Protect the process and thread objects with a denying DACL. This approach, obviously, works against unprivileged tools but won't interfere with administrators that have the Debug privilege.
2. Occupying the debug port beforehand and thus, preventing anyone from using it. **SuspendMe** combines it with injection prevention, so freezing it via debugging would require overcoming both obstacles.
3. Other techniques that can prevent debuggers from attaching or injecting threads.

### Overview
Pros                   | Cons
---------------------- | ----
Freezes future threads | Requires keeping a handle open 

## Freezing via a Job Object

### Idea
Job objects provide a mechanism for manipulating and monitoring a group of processes as a single entity. Additionally, they allow enforcing various limits and constraints on their execution, configurable through the [`NtSetInformationJobObject`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntpsapi.h#L2062-L2070) function. Starting from Windows 8, jobs also support freezing processes through the corresponding `JobObjectFreezeInformation` info class. The primary advantage of this technique is that it relies on deep freezing - an operation that is not susceptible to race conditions and takes care of the new threads out-of-the-box.

Before we can freeze a process, we need to put it into a job using [`NtAssignProcessToJobObject`](https://github.com/processhacker/processhacker/blob/c28efff632e76f1cb60aeb798a4cceae1289f3dd/phnt/include/ntpsapi.h#L2027-L2033). Note that this operation is irreversible and, therefore, should be taken with care. Fortunately, starting from Windows 8, a process can be part of multiple jobs. Although they must form a hierarchy, we are unlikely to run into conflicts between the restrictions they enforce as long as we don't configure any.

As you can guess, this technique also requires keeping a handle open. While we already encountered a similar problem with debugging, here it's more severe: closing the last handle to a frozen job makes it impossible to unfreeze the processes within it. The system does not expose any functions for opening a job aside from doing it by name, and names get disassociated with the last closed handle. Given enough access, we can, of course, store a backup copy in the target's handle table to prevent this scenario from happening.

### Bypasses
Deep freezing is designed to provide substantial reliability guarantees. I didn't manage to find any weaknesses that allow the process to execute code in a deep-frozen state, so there aren't many options left. Looking into the possibilities for preventing freezing from happening, we can try the following ideas:

1. Protect the process and thread objects with a denying DACL. Again, it won't stop administrators that have the Debug privilege.
2. Craft and employ a specific job hierarchy that will conflict with the new job, failing its assignment. I didn't manage to exploit this attack vector when we don't enforce any additional limits, but it might be possible, considering the assignment logic.

### Overview
Pros                   | Cons
-----------------------| ----
Freezes future threads | Requires keeping a handle open
_-_                    | Requires Windows 8 and above
_-_                    | Permanently assigns the process to a job

## Freezing via a State Change Object

### Idea
Suspending threads and processes via functions like `NtSuspendThread` and `NtSuspendProcess` looks somewhat similar to synchronizing with external resources: it requires an explicit release operation. What happens when a process that, say, acquired a shared mutex crashes unexpectedly? The system releases the ownership automatically when it destroys the process's handle table. Despite similarities, it does not happen with acquired suspension. Not long ago, Microsoft, apparently, decided to address this issue by introducing an alternative approach for dealing with suspension. [Windows Insider Preview 20190 introduced](https://twitter.com/hFireF0X/status/1295995982409236480) a new **ProcessStateChange** type for kernel objects, followed by a similar **ThreadStateChange** that [appeared in 20226](https://twitter.com/hFireF0X/status/1311528429112754176). The new syscalls [documented here](https://windows-internals.com/thread-and-process-state-change/) tie suspend and resume actions to these objects. Because these objects record performed operations, the system can undo them automatically when it destroys the object. In practice, you call `NtCreateProcessStateChange`, then apply suspension via `NtChangeProcessState`. To resume the process, either call `NtCreateProcessStateChange` again specifying the corresponding action or merely close the object and let the system handle everything on its own.

Interestingly, this functionality initially worked on top of the same routines that power the ordinary suspension (`PsSuspendProcess` and `PsSuspendThread`) and, therefore, was vulnerable to the entire spectrum of attacks we discussed earlier. However, somewhere between builds 20231 and 21286, they replaced process-wide suspension with freezing (via `PsFreezeProcess`), making it significantly more reliable. Considering that Microsoft made freezing and deep-freezing essentially equivalent around the same time, this technique has great potential for powering system tools that require high reliability in the future.

### Bypasses
Yet again, out of the methods I included with the repository, nothing really breaks freezing in a form implemented in recent Insider builds. There, of course, might be something I missed that still differentiates freezing from deep-freezing and, therefore, allows creating active threads in a frozen process. Although, I don't see any working options other than the most boring one we already mentioned multiple times: preventing the process from being opened by an unprivileged caller with a denying DACL.

### Overview
Pros                   | Cons
-----------------------| ----
Freezes future threads | Requires keeping a handle open
_-_                    | Requires Windows Insider Preview

# Tools

You can download the tools from the [releases page](https://github.com/diversenok/Suspending-Techniques/releases).

## SuspendTool

The tool implements all of the techniques for suspending and freezing processes I discuss above.

```text
Available options:

[0] Enumerate & suspend all threads
[1] Enumerate & resume all threads
[2] Suspend via NtSuspendProcess
[3] Resume via NtResumeProcess
[4] Suspend via a debug object
[5] Freeze via a debug object
[6] Freeze via a job object
[7] Freeze via a state change object
```

## SuspendMe

This program tries its best to bypass or at least counteract specific suspension methods.

```text
Available options:

[0] Protect the process with a denying security descriptor
[1] Circumvent suspension using a race condition
[2] Create a thread pool for someone to trigger
[3] Hijack thread execution (resume & detach debuggers on code injection)
[4] Start self-debugging so nobody else can attach
```

## InjectTool

You can use this tool to check how a specific technique responds to thread creation. Additionally, you can use it to help the **SuspendMe** tool escape when it works in thread-hijacking mode. When used for direct injection, the thread will execute [`NtAlertThread`](https://github.com/processhacker/processhacker/blob/d6e5d36d2c6c2523d55a6f07a6447bf9eca569db/phnt/include/ntpsapi.h#L1445-L1450). I chose this function because it matches the expected prototype and exits immediately.

```text
Available options:

[0] Create a thread
[1] Create a thread (hide from DLLs & debuggers)
[2] Trigger thread pool's thread creation
```

## ModeTransitionMonitor

Process statistics don't provide enough information to reliably identify user-mode code execution. **UserTime** is not precise enough to detect running a single line of code, while **CycleTime** does not distinguish between user and kernel modes. Of course, if a program spins in a tight loop and consumes 100% of the CPU, we don't need any sophisticated tricks. As for the rest, I wrote a program that installs the **Instrumentation Callback** within the target process (see [slides by Alex Ionescu](https://github.com/ionescu007/HookingNirvana/blob/9e4e8e326b9dfd10a7410986486e567e5980f913/Esoteric%20Hooks.pdf) and a [blog post by Antonio Cocomazzi](https://splintercod3.blogspot.com/p/weaponizing-mapping-injection-with.html)). The system invokes this callback every time it returns from the kernel mode, making it possible to identify when any wait completes. As a bonus, we can record return addresses and get a better insight into what happens within the target.

Technically, we need the Debug privilege to install the instrumentation callback for another process. But since setting it on the current one does not require anything, we can easily bypass this requirement by injecting a thread that installs the callback on the target's behalf.

```text
Do you want to capture return addresses? [y/n]: y
Loading symbols...

Target's PID or a unique image name: SuspendMe
Setting up monitoring...

Transitions / second: 0

Transitions / second: 6
  ntdll.dll!ZwQueryInformationThread+0x14 x 3 times
  ntdll.dll!ZwAlertThread+0x14
  ntdll.dll!NtTestAlert+0x14
  ntdll.dll!LdrInitializeThunk

Transitions / second: 0
```

## SuspendInfo

**SuspendInfo** is a small program that inspects and displays suspension/freezing info for all threads in a process.

# Conclusion

I was surprised to learn that the most commonly used techniques utilized by both first- and third-party tools have reliability issues that allow a specially crafted program to circumvent them. We saw that Microsoft takes the steps in the right direction: first, they introduced job-based deep-freezing, then significantly improved ordinary freezing and included a great alternative solution. The debugging-based technique turned out to be full of peculiar pitfalls and weaknesses, but with some tweaking, it might be a better option than using `NtSuspendProcess` in tools like Process Hacker.

Feel free to use the [Discussions page](https://github.com/diversenok/Suspending-Techniques/discussions) for sharing your ideas on improving, bypassing, or utilizing suspension techniques.
