"""
Cython version:
2017-11-12 19:02:05,842 [59823] INFO     __main__: Global epoch 0 start.
2017-11-12 19:02:08,178 [59823] DEBUG    model.APV_MCTS_2_C: Searched for 2.33579 seconds
2017-11-12 19:02:08,179 [59823] DEBUG    __main__:
None
2017-11-12 19:02:08,179 [59823] INFO     __main__: Self-Play Simulation Game #0: 2.337 seconds

Python version
*** PROFILER RESULTS ***
suggest_move_prob (/Users/yuhang/Desktop/AlphaGOZero-python-tensorflow/model/APV_MCTS_2.py:226)
function called 1 times

         5196291 function calls (5189435 primitive calls) in 3.667 seconds


   Ordered by: cumulative time, internal time, call count
   List reduced from 297 to 40 due to restriction <40>

   ncalls  tottime  percall  cumtime  percall filename:lineno(function)
        1    0.001    0.001    3.669    3.669 APV_MCTS_2.py:226(suggest_move_prob)
        1    0.013    0.013    3.567    3.567 {method 'run_until_complete' of 'uvloop.loop.Loop' objects}
     4170    0.011    0.000    3.531    0.001 APV_MCTS_2.py:246(tree_search)
7879/2634    0.044    0.000    3.502    0.001 APV_MCTS_2.py:113(start_tree_search)
     3509    0.447    0.000    1.580    0.000 {built-in method builtins.max}
     1035    0.007    0.000    1.539    0.001 APV_MCTS_2.py:88(expand)
     1035    0.302    0.000    1.526    0.001 APV_MCTS_2.py:91(<dictcomp>)
  1270258    0.350    0.000    1.133    0.000 APV_MCTS_2.py:189(<lambda>)
  1270258    0.416    0.000    0.783    0.000 APV_MCTS_2.py:65(action_score)
   374670    0.562    0.000    0.625    0.000 index_tricks.py:516(__next__)
   374670    0.600    0.000    0.600    0.000 APV_MCTS_2.py:50(__init__)
  1270258    0.367    0.000    0.367    0.000 APV_MCTS_2.py:61(Q)
     1600    0.004    0.000    0.133    0.000 APV_MCTS_2.py:81(compute_position)
     1600    0.011    0.000    0.129    0.000 go.py:354(play_move)
     1035    0.005    0.000    0.107    0.000 features.py:116(extract_features)
        1    0.000    0.000    0.088    0.088 Network.py:91(run_many)
        1    0.000    0.000    0.088    0.088 session.py:781(run)
        1    0.000    0.000    0.088    0.088 session.py:1036(_run)
        1    0.000    0.000    0.087    0.087 session.py:1258(_do_run)
        1    0.000    0.000    0.087    0.087 session.py:1321(_do_call)
        1    0.000    0.000    0.087    0.087 session.py:1290(_run_fn)
        1    0.087    0.087    0.087    0.087 {built-in method _pywrap_tensorflow_internal.TF_Run}
"""
from _asyncio import Future
import asyncio
from asyncio.queues import Queue
import uvloop
asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())

from profilehooks import profile
import logging

import sys
import time
import numpy as np
from numpy.random import dirichlet
from collections import namedtuple
import logging
import daiquiri

daiquiri.setup(level=logging.DEBUG)
logger = daiquiri.getLogger(__name__)

import utils.go as go
from utils.features import extract_features,bulk_extract_features

# All terminology here (Q, U, N, p_UCT) uses the same notation as in the
# AlphaGo paper.
# Exploration constant
c_PUCT = 5

class MCTSPlayerMixin(object):

    now_expanding = set()
    # queue size should be >= the number of semmphores
    # in order to maxout the coroutines
    # There is not rule of thumbs to choose optimal semmphores
    # And keep in mind: the more coroutines, the less (?) quality (?)
    # of the Monte Carlo Tree obtains. As my searching is less deep
    # w.r.t a sequential MCTS. However, since MCTS is a randomnized
    # algorithm that tries to approximate a value by averaging over run_many
    # random processes, the quality of the search tree is hard to define.
    # It's a trade off among time, accuracy, and the frequency of NN updates.
    sem = asyncio.Semaphore(64)
    queue = Queue(64)
    QueueItem = namedtuple("QueueItem", "feature future")
    loop = asyncio.get_event_loop()
    running_simulation_num = 0

    __slot__ = ["parent","move","prior","position","children","U",
                "N","W"]

    def __init__(self, parent, move, prior):
        self.parent = parent # pointer to another MCTSNode
        self.move = move # the move that led to this node
        self.prior = prior
        self.position = None # lazily computed upon expansion
        self.children = {} # map of moves to resulting MCTSNode
        self.U,self.N,self.W = 0,0,0

    def __repr__(self):
        return f"<MCTSNode move=self.move prior=self.prior score=self.action_score is_expanded=self.is_expanded()>"

    @property
    def Q(self):
        return self.W/self.N if self.N != 0 else 0

    @property
    def action_score(self):
        return self.Q + self.U

    def virtual_loss_do(self):
        self.N += 3
        self.W -= 3

    def virtual_loss_undo(self):
        self.N -= 3
        self.W += 3

    def is_expanded(self):
        return self.position is not None

    #@profile
    def compute_position(self):
        """Evolve the game board, and return current position"""
        position = self.parent.position.play_move(self.move)
        self.position = position
        return position

    #@profile
    def expand(self, move_probabilities):
        """Expand leaf node"""
        #api,parent = self.api,self
        self.children = {move: MCTSPlayerMixin(self,move,prob)
            for move, prob in np.ndenumerate(np.reshape(move_probabilities[:-1],(go.N,go.N)))}
        # Pass should always be an option! Say, for example, seki.
        self.children[None] = MCTSPlayerMixin(self,None,move_probabilities[-1])

    def backup_value_single(self,value):
        """Backup value of a single tree node"""
        self.N += 1
        if self.parent is None:

            # No point in updating Q / U values for root, since they are
            # used to decide between children nodes.
            return

        # This incrementally calculates node.Q = average(Q of children),
        # given the newest Q value and the previous average of N-1 values.
        self.W, self.U = (
            self.W + value,
            c_PUCT * np.sqrt(self.parent.N) * self.prior / self.N,
        )
        #self.Q = self.W/self.N

    async def start_tree_search(self):

        # add virtual loss
        self.virtual_loss_do()

        #TODO: add proper game over condition
        now_expanding = self.__class__.now_expanding

        while self in now_expanding:
            await asyncio.sleep(1e-4)

        if not self.is_expanded(): #  is leaf node

            # add leaf node to expanding list
            now_expanding.add(self)

            # compute leaf node position
            pos = self.compute_position()

            if pos is None:
                #logger.debug("illegal move!")
                # See go.Position.play_move for notes on detecting legality
                # In Go, illegal move means loss (or resign)
                # subtract virtual loss imposed at the beginnning
                self.virtual_loss_undo()
                self.backup_value_single(-1)
                now_expanding.remove(self)
                return -1*-1

            """Show thinking history for fun"""
            #logger.debug(f"Investigating following position:\n{self.position}")

            # perform dihedral manipuation
            flip_axis,num_rot = np.random.randint(2),np.random.randint(4)
            dihedral_features = extract_features(pos,dihedral=(flip_axis,num_rot))

            # push extracted dihedral features of leaf node to the evaluation queue
            future = await self.__class__.push_queue(dihedral_features)  # type: Future
            await future
            move_probs, value = future.result()

            # perform reversed dihedral maniputation to move_prob
            move_probs = np.append(np.reshape(np.flip(np.rot90(np.reshape(\
            move_probs[:-1],(go.N,go.N)),4-num_rot),axis=flip_axis),(go.N**2,)),move_probs[-1])

            # expand by move probabilities
            self.expand(move_probs)

            # subtract virtual loss imposed at the beginnning
            self.virtual_loss_undo()

            # back up value just for current tree node
            self.backup_value_single(value[0])

            # remove leaf node from expanding list
            now_expanding.remove(self)

            # must invert, because alternative layer has opposite objective
            return value[0]*-1

        else: # not a leaf node
            '''
            # perform dirichlet perturbed action score
            all_action_score = [child.Q + \
            child.U*(0.75+0.25*(noise)/(child.prior+1e-8)) for child,noise in\
            zip(self.children.values(),dirichlet([0.03]*362))]

            move2action_score = {move:action_score for move,action_score in \
            zip(self.children.keys(),all_action_score)}

            # select the move with maximum action score
            select_move = max(move2action_score, key=move2action_score.get)
            # start async tree search from child node
            # select_move = (np.random.randint(19), np.random.randint(19))
            value = await self.children[select_move].start_tree_search()
            '''
            child = max(self.children.values(), key=lambda node: node.action_score)
            value = await child.start_tree_search()

            # subtract virtual loss imposed at the beginning
            self.virtual_loss_undo()

            # back up value just for current node
            self.backup_value_single(value)

            # must invert
            return value*-1

    @classmethod
    def set_network_api(cls, net):
        cls.api = net

    @classmethod
    def run_many(cls,bulk_features):
        return cls.api.run_many(bulk_features)
        """simulate I/O & evaluate"""
        #sleep(np.random.random()*5e-2)
        #return np.random.random((len(bulk_features),362)), np.random.random((len(bulk_features),1))

    @classmethod
    def set_root_node(cls, root: object):
        cls.ROOT = root
        cls.NOW_EXPANDING = set()
        if root.parent is not None:
            """Help python interpreter to collect garbage???"""
            del root.parent.children

    @classmethod
    def move_prob(cls):
        prob = np.asarray([child.N for child in cls.ROOT.children.values()]) / cls.ROOT.N
        prob /= np.sum(prob) # ensure 1.
        return prob

    @classmethod
    def suggest_move_prob(cls, position, iters=1600):
        """Async tree search controller"""
        start = time.time()

        if cls.ROOT.parent is None:
            move_probs,_ = cls.api.run_many(bulk_extract_features([position]))
            cls.ROOT.position = position
            cls.ROOT.expand(move_probs[0])

        coroutine_list = []
        for _ in range(iters):
            coroutine_list.append(cls.tree_search())
        coroutine_list.append(cls.prediction_worker())
        cls.loop.run_until_complete(asyncio.gather(*coroutine_list))

        logger.debug(f"Searched for {(time.time() - start):.5f} seconds")
        return cls.move_prob()

    @classmethod
    async def tree_search(cls):
        """Asynchrounous tree search with semaphores"""

        cls.running_simulation_num += 1

        # reduce parallel search number
        with await cls.sem:

            value = await cls.ROOT.start_tree_search()
            #logger.debug(f"value: {value}")
            #logger.debug(f'Current running threads : {running_simulation_num}')
            cls.running_simulation_num -= 1

            return value

    @classmethod
    async def prediction_worker(cls):
        """For better performance, queueing prediction requests and predict together in this worker.
        speed up about 45sec -> 15sec for example.
        """
        q = cls.queue
        margin = 10  # avoid finishing before other searches starting.
        while cls.running_simulation_num> 0 or margin > 0:
            if q.empty():
                if margin > 0:
                    margin -= 1
                await asyncio.sleep(1e-3)
                continue
            item_list = [q.get_nowait() for _ in range(q.qsize())]  # type: list[QueueItem]
            #logger.debug(f"predicting {len(item_list)} items")
            bulk_features = np.asarray([item.feature for item in item_list])
            policy_ary, value_ary = cls.run_many(bulk_features)
            for p, v, item in zip(policy_ary, value_ary, item_list):
                item.future.set_result((p, v))

    @classmethod
    async def push_queue(cls, features):
        future = cls.loop.create_future()
        item = cls.QueueItem(features, future)
        await cls.queue.put(item)
        return future