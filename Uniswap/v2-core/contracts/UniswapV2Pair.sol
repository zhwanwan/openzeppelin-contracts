pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

// 配对合约：管理流动性资金池，不同币对有着不同的配对合约实例，如USDT-WETH这一个币对，就对应一个配对合约实例，DAI-WETH又对应另一个配对合约实例。
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    //最小流动性
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    //SELECTOR常量值为`transfer(address,uint256)`字符串哈希值的前4位16进制数字
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory; //工厂地址
    address public token0; //token0地址
    address public token1; //token1地址

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    // 记录更新的区块时间
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    //token0的累积价格
    uint public price0CumulativeLast;
    //token1的累积价格
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint private unlocked = 1;
    
    //防止重入
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        //调用token合约地址的低级transfer方法
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        //确认返回值为true并且返回的data长度为0或者解码后为true
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    //同步事件
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        // 将msg.sender设为factory
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    // 初始化函数的目的：create2汇编创建合约的方式限制了构造函数不能有参数
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    /**
    TWAP=Time-Weighted Average Price，即加权平均价格，可用来创建有效防止价格操纵的链上价格预言机。
    price0CumulativeLast：token0的累积价格
    price1CumulativeLast：token1的累积价格
    blockTimestampLast： 记录更新的区块时间
    _update函数在每次mint、burn、swap、sync时都会触发更新。
    ---------------------------------------------------------
    TWAP逻辑如下：
    token0 和 token1 的当前价格，其实可以根据以下公式计算所得：
    price0 = reserve1 / reserve0
    price1 = reserve0 / reserve1
    比如，假设两个 token 分别为 WETH 和 USDT，当前储备量分别为 10 WETH 和 40000 USDT，那么 WETH 和 USDT 的价格分别为：
    price0 = 40000/10 = 4000 USDT
    price1 = 10/40000 = 0.00025 WETH
    现在，再加上时间维度来考虑。比如，当前区块时间相比上一次更新的区块时间，过去了 5 秒，那就可以算出这 5 秒时间的累加价格：
    price0Cumulative = reserve1 / reserve0 * timeElapsed = 40000/10*5 = 20000 USDT
    price1Cumulative = reserve0 / reserve1 * timeElapsed = 10/40000*5 = 0.00125 WETH
    假设之后再过了 6 秒，最新的 reserve 分别变成了 12 WETH 和 32000 USDT，则最新的累加价格变成了：
    price0CumulativeLast = price0Cumulative + reserve1 / reserve0 * timeElapsed = 20000 + 32000/12*6 = 36000 USDT
    price1CumulativeLast = price1Cumulative + reserve0 / reserve1 * timeElapsed = 0.00125 + 12/32000*6 = 0.0035 WETH
    这就是合约里所记录的累加价格了。
    另外，每次计算时因为有 timeElapsed 的判断，所以其实每次计算的是每个区块的第一笔交易。
    而且，计算累加价格时所用的 reserve 是更新前的储备量，所以，实际上所计算的价格是之前区块的，因此，想要操控价格的难度也就进一步加大了。
    --------------------------------------------------------
    计算TWAP即时间加权平均价格公式：
    为了简化，我们将前面 5 秒时间的时刻记为 T1，累加价格记为 priceT1，而 6 秒时间后的时刻记为 T2，累加价格记为 priceT2。如此，可以计算出，在后面 6 秒时间里的平均价格：
    TWAP = (priceT2 - priceT1)/(T2 - T1) = (36000 - 20000)/6 = 2666.66
    在实际应用中，一般有两种计算方案，一是固定时间窗口的 TWAP，二是移动时间窗口的 TWAP。
    在 uniswap-v2-periphery 项目中，examples 目录下提供了这两种方案的示例代码，分为是 ExampleOracleSimple.sol 和 ExampleSlidingWindowOracle.sol。
    */
    // update reserves and, on the first call per block, price accumulators
    //更新，包括1：更新reverse0和reverse1; 2:累积计算price0CumulativeLast和price1CumulativeLast，这两个价格用来计算TWAP（时间加权平均价格）。
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // 检查配对合约的两个token余额没有溢出
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // 读取当前区块时间，保留低32位
        uint32 blockTimestamp = uint32(block.timestamp % 2**32); //保留低32位
        // 计算出与上一次更新的区块时间直接的时间差timeElapsed
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // 如果timeElapsed>0且两个token的储备量都不为0，则更新累积价格
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // 累加计算price{0,1}CumulativeLast，这两个价格用来计算TWAP（Time-Weighted Average Price，即【时间加权平均价格】）
            // 这两个值将会在价格预言机中使用
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        // 更新储备量
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        // 触发同步事件
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        //查询工厂合约的feeTo变量值
        address feeTo = IUniswapV2Factory(factory).feeTo();
        //如果feeTo不为零地址，feeOn等于true否则为false
        feeOn = feeTo != address(0);
        //定义k值
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                //计算(_reserve0 * _reserve1)的平方根
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                //计算k值的平方根
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    //分子 = ERC20总量 * (rootK - rootKLast)
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    //分母 = rootK * 5 + rootKLast
                    uint denominator = rootK.mul(5).add(rootKLast);
                    //流动性 = 分子 / 分母
                    uint liquidity = numerator / denominator;
                    //如果流动性大于0，将流动性铸造给feeTo地址
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // 添加流动性：通过同时注入两种代币资产来获取流动性代币，返回流动性数量
    // 调用该函数之前，路由合约已经完成了将用户的代币数量划转到该配对合约的操作。
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) { // lock防重入
        // 获得池子里两个代币原有的数量
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 获取两个代币的当前余额
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        // 获取两个代币的投入数量
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        //计费协议费用：工厂合约有一个feeTo地址，如果设置了该地址不为零地址，就表示添加和移除流动性会收取协议费用，但Uniswap一直到现在都没有设置该地址
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            //totalSupply为0时，流动性代币数量为两个代币投入的数量相乘后求平方根，结果再减去最小流动性(1000)，该最小流动性永久锁在零地址。
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            //将最小流动性1000永久锁在零地址
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            //如果不是提供最初流动性的话，流动性代币取下面二者最小值
            // 流动性= 新增代币数量 / 已有代币总量 * 总的流动性 
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 铸造出liquidity数量的LP token并给到用户
        _mint(to, liquidity);

        //更新，包括1：更新reverse0和reverse1; 2:累积计算price0CumulativeLast和price1CumulativeLast，这两个价格用来计算TWAP（时间加权平均价格）。
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果协议费用开启的话，更新kLast值，即reverse0和reverse1乘积值，该值其实只在计算协议费用时用到。固定乘积做市商k = x * y。
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        //触发铸造事件
        emit Mint(msg.sender, amount0, amount1);
    }

    // 移除流动性：销毁流动性代币并提取相应的两种代币资产给到用户
    // 路由合约会先把用户的流动性代币转到该配对合约里
    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        //获取两个储备量
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        // 获取配对合约在两个代币的当前余额
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        // 获取当前地址的【流动性代币(LP Token)余额】，正常情况下，配对合约里是不会有流动性代币的，因为所有的流动性代币都是给到了流动性提供者的。
        // 而这里有值，其实是因为路由合约会先把用户的流动性代币转到该配对合约里。
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取总的LP Token数量
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // 提取代币数量 = 用户流动性 / 总流动性 * 代币总余额
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        // 销毁掉流动性代币
        _burn(address(this), liquidity);
        // 将两个代币资产计算所得数量从配对合约划转到用户
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        // 重新获取配对合约在两个token的余额（转走了一部分）
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        
        //更新，包括1：更新reverse0和reverse1; 2:累积计算price0CumulativeLast和price1CumulativeLast，这两个价格用来计算TWAP（时间加权平均价格）。
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果协议费用开启的话，更新kLast值，即reverse0和reverse1乘积值，该值其实只在计算协议费用时用到。固定乘积做市商k = x * y。
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // 兑换，4个入参，amount0Out和amount1Out表示兑换结果要转出的token0和token1的数量，这两个值通常情况下一个为0，另一个不为0，但使用闪电交易时可能两个都不为0。
    // to参数则是接收者地址（配对合约或者最后实际接收方），最后的data参数是执行回调时的传递数据，通过路由合约兑换的话，该值为0。
    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        // 这里用了一对大括号，这是为了限制_token{0,1}这两个临时变量的作用域，防止堆栈太深导致gas超出错误。
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        // 将代币从当前配对合约划转到接收者地址（其他配对合约或者最终接收者）
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        // 如果data参数大于0，则将to地址转为IUniswapV2Callee并调用其uniswapV2Call函数，者其实就是一个回调函数，to地址需要实现该接口
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data); //这里其实就是闪电贷
        // 获取两个代币的当期余额balance{0,1}，而这个余额就是扣减转出代币后的余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        // 计算实际转入的代币数量。实际转入的数量其实也通常是一个为0，一个不为0的。
        // 举例：假如转入的是token0，转出的是token1，转入数量为100，转出数量为200，那么：
        // amount0In = 100
        // amount1In = 0
        // amount0Out = 0
        // amount1Out = 200
        // 而reverse0和reverse1假设分别为1000和2000，没进行兑换交易之前，balanace{0,1}和reverse{0,1}是相等的。
        // 而完成了代币的转入和转出之后，其实，balance0就变成了1000+100-0=1100，balance1变成了2000+0-200=1800，公式如下：
        // balance0 = reverse0 + amount0In - amount0Out
        // balance1 = reverse1 + amount1In - amount1Out
        // 反推一下就得到： amountIn = balance - (reverse - amountOut)
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        // 进行扣减交易手续费后的恒定乘积校验 0Adjusted * 1Adjusted >= 储备0 * 储备1 * 1000000
        // 校验公式：(x1-0.003*Xin)*(y1-0.003*Yin) >= x0 * y0，公式成立说明这个底层兑换之前的确已经收过交易手续费了（getAmountsOut函数）
        // 校验公式等价于：(x1*1000-3*Xin)*(y1*1000-3*Yin) >= x0 * y0 * 1000 * 1000 
        // 其中0.003是交易手续费率，x0和y0就是reverse0和reverse1，x1和y1则是balance0和balance1，Xin和Yin则对应于amount0In和amount1In    
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }
        //更新，包括1：更新reverse0和reverse1; 2:累积计算price0CumulativeLast和price1CumulativeLast，这两个价格用来计算TWAP（时间加权平均价格）。
        _update(balance0, balance1, _reserve0, _reserve1);
        // 触发交换事件
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // 强制平衡以匹配储备
    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        //将配对合约在token0和token1的余额减去各自的储备量安全发送到to地址
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // 强制准备金与余额匹配
    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
    
    /**
    sync()和skim()
    为了防止可能更新配对合约余额的定制令牌实现并更优雅地处理总供应量大于2^112的令牌，Uniswap具有两个纾困功能：sync()和skim()。
    如果令牌异步缩小一对货币对的余额，sync()充当恢复机制。在这种情况下，交易将获得次优利率，并且如果没有流动性提供者愿意纠正这种情况，则该交易将被卡住。
    sync()存在可以将合约的储备金设置为当前余额，从而可以从这种情况下略微恢复。
    如果将足够的令牌发送到代币对以使两个unit112存在槽中的储备金溢出，skim()将用作恢复机制，否则可能导致交易失败。skim()允许用户提取代币对当前余额与储备之间的差额。
    **/
}
