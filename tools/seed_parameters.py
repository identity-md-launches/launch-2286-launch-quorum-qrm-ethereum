"""Integer single-sided pool parameters reconstructed from published IMD launch input.
Tick conversion follows the vendored MIT Uniswap v4 TickMath source.
Not a claim that IMD's private deployer implementation has been inspected.
"""
import functools
import hashlib
import json
import math
import re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
Q96=1<<96
IMD='0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7'
@functools.lru_cache()
def factors():
    source=(ROOT/'lib/v4-core/src/libraries/TickMath.sol').read_text(encoding='utf-8')
    found=re.findall(r'if \(absTick & (0x[0-9a-f]+) != 0\) price = \(price \* (0x[0-9a-f]+)\) >> 128;',source)
    if len(found)!=19:raise ValueError('Review changed TickMath source before using calculator')
    return [(int(bit,16),int(value,16)) for bit,value in found]
def sqrt_at_tick(tick):
    if not -887272<=tick<=887272:raise ValueError('Tick bounds')
    n=abs(tick);p=0xfffcb933bd6fad37aa2d162d1a594001 if n&1 else 1<<128
    for bit,multiplier in factors():
        if n&bit:p=(p*multiplier)>>128
    if tick>0:p=((1<<256)-1)//p
    return (p+(1<<32)-1)>>32
def tick_at_sqrt(price):
    if not sqrt_at_tick(-887272)<=price<sqrt_at_tick(887272):raise ValueError('Price bounds')
    low,high=-887272,887272
    while low<high:
        middle=(low+high+1)//2
        if sqrt_at_tick(middle)<=price:low=middle
        else:high=middle-1
    return low
def parameters(project0,cap,supply,pool_bps=9000,spacing=60):
    if not (cap>0 and supply>0 and 0<pool_bps<=9000 and 0<spacing<=32767):raise ValueError('Inputs')
    numerator,denominator=(cap,supply) if project0 else (supply,cap)
    price=math.isqrt(numerator*(1<<192)//denominator)
    tick=tick_at_sqrt(price);max_tick=887272//spacing*spacing
    if project0:
        ceil_tick=tick+(sqrt_at_tick(tick)!=price)
        lower=((ceil_tick+spacing-1)//spacing)*spacing;upper=max_tick
    else:lower=-max_tick;upper=(tick//spacing)*spacing
    a,b=sqrt_at_tick(lower),sqrt_at_tick(upper);budget=supply*pool_bps//10000
    liquidity=budget*(a*b//Q96)//(b-a) if project0 else budget*Q96//(b-a)
    if not 0<liquidity<(1<<128):raise ValueError('Liquidity bounds')
    return {'sqrtPriceX96':price,'tickLower':lower,'tickUpper':upper,'liquidity':liquidity}
def policy34(project0):
    path=ROOT/'fixtures/policy/imd-public-policies.json'
    policy=next(p for p in json.loads(path.read_text(encoding='utf-8'))['policies'] if p['version']==34)
    terms=policy['params']
    if terms['chainId']!=1 or policy['kind']!='univ4_hook' or terms['feeTiers']!=[12500]:raise ValueError('Policy identity')
    cap=int(terms['initialMarketCaps'][IMD]);supply=int(terms['totalSupply'])
    result=parameters(project0,cap,supply)
    result.update({'policyVersion':34,'policySourceSha256':hashlib.sha256(path.read_bytes()).hexdigest(),
        'openingCapIMDMinorUnits':str(cap),'source':'fixtures/policy/imd-public-policies.json',
        'formulaEvidence':'fixtures/policy/imd-public-launch-parameters.json',
        'calculatorSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
    return result
def verify_public_example():
    sample=json.loads((ROOT/'fixtures/policy/imd-public-launch-parameters.json').read_text(encoding='utf-8'))
    expected=sample['selected'];got=policy34(True)
    checks={k:got[k]==expected[k] for k in ('sqrtPriceX96','tickLower','tickUpper','liquidity')}
    if not all(checks.values()):raise ValueError('Public launch differs: '+str(checks))
    return {'checks':checks,'matchedTransaction':sample['transactionHash'],
        'scope':'Exact public token0 launch match. Token1 ordering is separately exercised on local v4. No private deployer source claim.'}
if __name__=='__main__':print(json.dumps(verify_public_example()))
