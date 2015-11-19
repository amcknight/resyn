import sys
import os, os.path
import platform
import shutil
import time
import re
import difflib
from subprocess import call, check_output
from colorama import init, Fore, Back, Style

# Parameters
SYNQUID_PATH_LINUX = '../dist/build/synquid/synquid'
SYNQUID_PATH_WINDOWS = '../src/Synquid.exe'
BENCH_PATH = '.'
LOGFILE_NAME = 'run_all.log'
ORACLE_NAME_WINDOWS = 'oracle'
ORACLE_NAME_LINUX = 'oracle_nx'
OUTFILE_NAME = 'run_all.csv'
COMMON_OPTS = ['--print-solution-size=True', '--print-spec-info=True']

BENCHMARKS = [
    # Integers
    ["Integer",
        [('Int-Max2', 'maximum of 2 elements', []),
        ('Int-Max3', 'maximum of 3 elements', []),
        ('Int-Max4', 'maximum of 4 elements', []),
        ('Int-Max5', 'maximum of 5 elements', []),
        ('Int-Add', 'addition', [])]
    ],
    # Lists
    ["List",
        [('List-Null', 'is list empty', []),
        ('List-Elem', 'contains an element', []),
        ('List-Stutter', 'addition', []),
        ('List-Replicate', 'list of element repetitions', []),
        ('List-Append', 'append two lists', ['-m=1']),
        ('List-Concat', 'concatenate list of lists', []),
        ('List-Take', 'take first n elements', []),
        ('List-Drop', 'drop last n elements', []),
        ('List-Delete', 'delete given element', []),
        ('List-Map', 'list map', []),
        ('List-ZipWith', 'list zip with', []),
        ('List-Zip', 'zip two lists', []),
        ('List-ToNat', 'list of integers to nats', []),
        ('List-Product', 'Cartesian product', [])]
    ],
    # Unique lists
    ["Unique list",
        [('UniqueList-Insert', 'insertion', []),
        ('UniqueList-Delete', 'deletion', []),
        ('List-Nub', 'deduplication', ['-f=FirstArgument', '-m=1']),
        ('List-Compress', 'merge consequtive equal elements', ['-h'])]
    ],
    ["Sorting",
    # Insertion Sort
        [('IncList-Insert', 'insertion', []),
        ('IncList-InsertSort', 'insertion sort', []),
        # Merge sort
        ('List-Split', 'balanced split', ['-s=1', '-m=3']),
        ('IncList-Merge', 'sorted merge', ['-h']),
        ('IncList-MergeSort', 'merge sort', ['-a=2', '-s=1', '-m=3']),
        # Quick sort
        ('List-Partition', 'partition', ['-s=1']),
        ('IncList-PivotAppend', 'append pivot', []),
        ('IncList-QuickSort', 'quick sort', ['-a=2', '-s=1'])]
    ],
    # Trees
    ["Trees",
        [('Tree-Elem', 'contains an element',[]),
        ('Tree-Flatten', 'flatten to a list', []),
        ('Tree-HBal', 'create balanced tree', [])]
    ],
    ["BST",
        [# Binary search tree
        ('BST-Member', 'contains an element', []),
        ('BST-Insert', 'insertion', []),
        ('BST-Delete', 'deletion', ['-m=1', '-e', '-a=2'])],
        ('BST-Sort', 'BST sort', [])
    ],
        # works with: -m=2 -e (fast), -m=2 slower
    ["Heap",
        # Binary heap
        [('BinHeap-Member', 'addition', [])]
    ],
    ["User",
        # Evaluation
        [('Evaluator', 'desugar AST', []),
        ('Evaluator-Vars', 'desugar AST with variables', [])]
    ]
]

ABS_BENCHMARKS = [
    # Integers
    ('Int-Max', []),
    # Lists
    ('List-Reverse', []),
    ('List-Fold', ['-e']),
    # Insertion Sort
    ('IncList-Insert', []),
]

RBT_BENCHMARKS = [
    ('RBT-Constructors', ['-m=0', '-a=2']),
    ('RBT-BalanceL', ['-m=1', '-a=2', '-u', '-h', '-f=DisableFixpoint']),
    ('RBT-BalanceR', ['-m=1', '-a=2', '-u', '-h', '-f=DisableFixpoint']),
    ('RBT-Balance', ['-m=2', '-a=2', '-u', '-h', '-f=DisableFixpoint']),
]

COMPONENTS = {
   "Int-Add": "integer",
   "List-Null": "bool",
   "List-Elem": "bool",
   "List-Replicate": "integer",
   "List-Take": "integer",
   "List-Drop": "integer",
   "List-Concat": "append",
   "List-ToNat": "map, negate",
   "List-Product": "map, append",
   "List-Nub": "bool, elem",
   "Tree-Elem": "bool",
   "Tree-Flatten": "append",
   "Tree-HBal": "integer",
   "IncList-InsertSort": "insert",
   "IncList-MergeSort": "split, merge",
   "IncList-QuickSort": "partition, pivotAppend",
   "BST-Member": "bool",
   "Evaluator": "integer",
   "Evaluator-Vars": "integer",
}

class SynthesisResult:
    def __init__(self, name, time, size, specSize, nMeasures, nComponents):
        self.name = name
        self.time = time
        self.size = size
        self.specSize = specSize
        self.nMeasures = nMeasures
        self.nComponents = nComponents

    def str(self):
        return self.name + ', ' + '{0:0.2f}'.format(self.time) + ', ' + self.size + ', ' + self.specSize + ', ' + self.nMeasures + ', ' + self.nComponents

def run_benchmark(name, opts, path=''):
    print name,

    with open(LOGFILE_NAME, 'a+') as logfile:
      start = time.time()
      logfile.seek(0, os.SEEK_END)
      return_code = call([synquid_path] + COMMON_OPTS + opts + [path + name + '.sq'], stdout=logfile, stderr=logfile)
      end = time.time()

      print '{0:0.2f}'.format(end - start),
      if return_code:
          print Back.RED + Fore.RED + Style.BRIGHT + 'FAIL' + Style.RESET_ALL
      else:
          lastLines = os.popen("tail -n 5 %s" % LOGFILE_NAME).read().split('\n')
          solutionSize = re.match("\(Size: (\d+)\).*$", lastLines[0]).group(1)
          specSize = re.match("\(Spec size: (\d+)\).*$", lastLines[1]).group(1)
          measures = re.match("\(#measures: (\d+)\).*$", lastLines[2]).group(1)
          components = re.match("\(#components: (\d+)\).*$", lastLines[3]).group(1)
          results [name] = SynthesisResult(name, (end - start), solutionSize, specSize, measures, components)
          print Back.GREEN + Fore.GREEN + Style.BRIGHT + 'OK' + Style.RESET_ALL

def postprocess():
    with open(OUTFILE_NAME, 'w') as outfile:
        for arr in BENCHMARKS:
            category = arr[0]
            benchArray = arr[1]
            outfile.write ('\multirow{')
            outfile.write (str(benchArray.__len__()))
            outfile.write ('}{*}[-2pt]{\\rotatebox{90}{')
            outfile.write (category)
            outfile.write ('}}')
            for (name, tableName, args) in benchArray:
                if name in results:
                    res = results [name]
                    outfile.write (' & ')
                    outfile.write (tableName)
                    outfile.write (' & ')
                    row = ' & ' + res.nMeasures + '& ' + res.nComponents + \
                    ' & ' + COMPONENTS.get(name, '') + \
                    ' & ' + res.size + '& ' + '{0:0.2f}'.format(res.time) + \
                    ' & ' + '{0:0.2f}'.format(res.time)  + '& ' + '{0:0.2f}'.format(res.time) + \
                    ' & ' + '{0:0.2f}'.format(res.time) + ' \\\\'
                    outfile.write (row)
                outfile.write ('\n')
            outfile.write ('\\hline')

        for (short_name, args) in ABS_BENCHMARKS:
            name = short_name + '-Abs'
            if name in results:
                res = results [name]
                outfile.write (res.str())
            outfile.write ('\n')

    if os.path.isfile(oracle_name):
        fromlines = open(oracle_name).readlines()
        tolines = open(LOGFILE_NAME, 'U').readlines()
        diff = difflib.unified_diff(fromlines, tolines, n=0)
        print
        sys.stdout.writelines(diff)

if __name__ == '__main__':
    init()
    results = {}

    if platform.system() == 'Linux':
        synquid_path = SYNQUID_PATH_LINUX
        oracle_name = ORACLE_NAME_LINUX
    else:
        synquid_path = SYNQUID_PATH_WINDOWS
        oracle_name = ORACLE_NAME_WINDOWS

    if os.path.isfile(LOGFILE_NAME):
      os.remove(LOGFILE_NAME)

    benchmarkArray = [item for array in BENCHMARKS for item in array[1]]
    #print([str(item) for item in benchmarkArray])
    for (name, _, args) in benchmarkArray:
        #print(str(name) + str(args))
        run_benchmark(name, args)
    print Back.YELLOW + Fore.YELLOW + Style.BRIGHT + 'Abstract refinements' + Style.RESET_ALL
    for (name, args) in ABS_BENCHMARKS:
        run_benchmark(name, args, 'abstract/')
    print Back.YELLOW + Fore.YELLOW + Style.BRIGHT + 'Red-Black-Trees' + Style.RESET_ALL
    for (name, args) in RBT_BENCHMARKS:
        run_benchmark(name, args, 'abstract/')        

    postprocess()

