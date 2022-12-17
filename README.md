# Distributed Cycle Detection for the Pony runtime

This repository contains in progress work on a new cycle detection protocol for the [Pony](https://github.com/ponylang/ponyc) runtime.

Currently in the runtime, cycle detector is done by a central actor that is responsible for collecting a single, unifying view of relationship between actors in order detect cycles and when appropriate, reap the members of the cycle. The existing cycle detector started as a fairly simple implementation, but as it's performance characteristics were improved, it grew more and more complicated. It it's current form, it is an exceedingly complicated beast that is easy to introduce safety issues into.

The distributed cycle detection protocol that we are designing will replace the existing central cycle detector with a protocol that allows actors to detect cycles on their own and for members of cycles to agree to reap themselves when appropriate.

The goal of this earliest work is to minimize the amount of message passing that must be done in order to operate the protocol. We are willing to pay a "reasonable sized" memory penalty in order to achieve reduced memory passing.

For a "normal Pony application" that has relatively stable actor relationships and runs for an extended time, the usage of the protocol should be not noticable from an application level performance level such that we could eventually consider replacing `--ponynoblock` with the cycle detection protocol always running for such applications. We might never remove `--ponynoblock` as for some classes of applications (those known to not have cycles by the programmer) it will perform better than the cycle detection protocol, however, our goal as stated is for the most "normal" Pony applications to not be able to realistically notice the difference in performance between the two.
