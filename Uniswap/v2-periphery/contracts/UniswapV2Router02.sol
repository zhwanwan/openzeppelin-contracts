pragma solidity =0.6.6;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './interfaces/IUniswapV2Router02.sol';
import './libraries/UniswapV2Library.sol';
import './libraries/SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

// 路由合约02版本，相比01版本主要增加了几个支持交税费的函数
contract UniswapV2Router02 is IUniswapV2Router02 {
    using SafeMath for uint;

    address public immutable override factory;
    address public immutable override WETH;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    /**
    tokenA和tokenB就是配对的两个代币
    amountADesired和amountBDesired是预期支付的两个代币的数量
    amountAMin和amountBMin是用户可接受的最小成交数量，一般由前端根据预期值和滑点值计算得出的
   （滑点值通过uniswap-v2-sdk/src/entities/trade.ts中computePriceImpact函数计算得来）。
    */
    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {//返回amountA和amountB最终需要支付的数量
        // create the pair if it doesn't exist yet
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) { // 配对不存在就创建配对
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        // 提取两个token的储备量
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            // 根据两个储备量和tokenA的预期支付额，计算出需要支付多少tokenB
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) { // 如果计算得出的结果值amountBOptimal不比amountBDesired大
                // 且不会小于amountBMin，
                require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
                // 就可以将amountADesired和amountBOptimal
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else { // 如果amountBOptimal大于amountBDesired
                // 则根据amountBDesired计算得出需要支付多少tokenA，得到amountAOptimal
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                // amountAOptimal 不大于 amountADesired 且不会小于 amountAMin
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
                // 将amountAOptimal 和 amountBDesired 作为结果值返回
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
    
    // 支持添加两种ERC20代币作为流动性
    /*
    tokenA和tokenB就是配对的两个代币
    amountADesired和amountBDesired是预期支付的两个代币的数量
    amountAMin和amountBMin是用户可接受的最小成交数量，一般由前端根据预期值和滑点值计算得出的（滑点值通过uniswap-v2-sdk/src/entities/trade.ts中computePriceImpact函数计算得来）。
    比如，预期值amountADesired为1000，设置的滑点为0.5%，那么可以计算出可接受的最小值amountAMin为1000*(1-0.5%)=995
    to是接受流动性代币的地址
    deadline是该笔交易的有效时间，如果超过该时间还没得到交易就直接失败不进行交易
    */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        // 调用UniswapV2Library 的 pairFor 函数计算出配对合约地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 接着就往 pair 地址进行转账了
        // 因为用了 transferFrom 的方式，所以用户调用该函数之前，其实是需要先授权给路由合约的。
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        // 最后再调用 pair 合约的 mint 接口就可以得到流动性代币 liquidity 了。
        liquidity = IUniswapV2Pair(pair).mint(to);
    }
    
    // addLiquidityETH 则支付的其中一个 token 则是 ETH，而不是 ERC20 代币
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value, // 预期支付的 ETH 金额也是直接从 msg.value 读取的，所以入参里也不需要 ETH 的 Desired 参数。
            amountTokenMin,
            amountETHMin
        );
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        // 将 ETH 转为 WETH 进行处理的, 将用户转入的ETH转成了WETH
        IWETH(WETH).deposit{value: amountETH}();
        // 从WETH合约转到配对合约
        assert(IWETH(WETH).transfer(pair, amountETH));
        // 流动性数量 = 配对合约铸造给to地址
        liquidity = IUniswapV2Pair(pair).mint(to);
        // refund dust eth, if any
        // 如果一开始支付的 msg.value 大于实际需要支付的金额，多余的部分将返还给用户。
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    
    // 移除流动性，本质上就是用流动性代币兑换出配对的两个代币。
    // 和addLiquidity相对应，会换回两种ERC20代币
    // **** REMOVE LIQUIDITY ****
    function removeLiquidity( 
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {// 返回得到两种代币的数量
        // 计算出 pair 合约地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 将流动性代币从用户划转到 pair 合约
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        // 执行 pair 合约的 burn 函数实现底层操作，返回了两个代币的数量
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        // 对两个代币做下排序,根据排序结果确定 amountA 和 amountB
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        // 检验是否大于滑点计算后的最小值
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }
    
    // 和addLiquidityETH相对应，换回的其中一种是主币ETH
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountToken, uint amountETH) {
        // 流动性池子里实际存储的是 WETH,调用 removeLiquidity 时第二个参数传的是 WETH
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        // 调用 WETH 的 withdraw 函数将 WETH 转为 ETH并转给路由合约
        IWETH(WETH).withdraw(amountETH);
        // 从路由合约将 ETH 转给用户
        TransferHelper.safeTransferETH(to, amountETH);
    }
    
    // 换回两种 ERC20 代币，但用户会提供签名数据使用 permit 方式完成授权操作（链下签名授权操作）
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountA, uint amountB) {
        //计算TokenA，TokenB的create2地址，无需进行任何外部调用
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        //如果全部批准，value值等于最大uint256，否则等于流动性
        uint value = approveMax ? uint(-1) : liquidity;
        //调用配对合约的批准方法（调用账户，当前合约地址，数组，最后期限，v,r,s）
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }
    
    // 使用 permit 完成授权操作，换回的其中一种是主币 ETH
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountToken, uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // 功能和 removeLiquidityETH 一样，不同的地方在于支持转账时支付费用
    /**
    该函数和removeLiquidityETH一样，但对比一下，主要不同点在于：
    1.返回值没有amountToken
    2.调用removeLiquidity后也没有amountToken值返回
    3.进行safeTransfer时传值直接读取当前地址的token余额
    有一些token其合约实现上，在进行transfer时候，就会扣掉部分金额作为费用或者作为税费缴纳，或锁仓处理，或替代ETH来支付GAS费。
    这类token在进行转账是会产生损耗的，实际到账的数额不一定就是传入的数额。该函数主要就是支持这类token。
    */
    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        (, amountETH) = removeLiquidity(//移除流动性，本质上就是用流动性代币兑换出配对的两个代币。
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),//注意这里先将两种代币转到路由合约，这是为了支持扣税，这样下面才可以将实际转入的数量转给最终to地址
            deadline
        );
        // 将路由合约的余额（已扣除手续费）转到to地址
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        // 调用 WETH 的 withdraw 函数将 WETH 转为 ETH并转给路由合约
        IWETH(WETH).withdraw(amountETH);
        // 从路由合约将 ETH 转给用户
        TransferHelper.safeTransferETH(to, amountETH);
    }
    
    // 功能和上一个函数一样，但支持使用链下签名的方式进行授权
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }

    /**
    兑换内部函数，需要保证初始提供量已转入第一个配对合约
    遍历整个路径，路径的token两两交换
    */
    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        // 交换的逻辑：遍历整个兑换路径，并对路径中每两个配对的token调用pair合约的兑换函数，实现底层的兑换处理。
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            //假设pair是A->B，从accounts取出兑换得到的B的数量
            uint amountOut = amounts[i + 1];
            //amount0Out和amount1Out表示兑换结果要转出的token0和token1的数量，这里一个为0，另一个不为0
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            //根据当前遍历位置，得到下一个交换发送的地址
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }
    
    // 用 ERC20 兑换 ERC20，但支付的数量是指定的，而兑换回的数量则是未确定的
    // 指定amountIn的兑换，比如用tokenA兑换tokenB，那amountIn就是指定支付的tokenA的数量，而兑换回来的tokenB的数量自然是越多越好。
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,//兑换路径，这是由前端SDK计算出最优路径后传给合约的。
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        // 1.计算出兑换数量
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        // 2.判断是否超过滑动计算后的最小值
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        // 3.将支付的tokenA转入第一个配对合约中
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        // 4.调用兑换的内部函数，需要保证初始提供量已转入第一个配对合约
        _swap(amounts, path, to);
    }
    
    // 指定 amountOut 的兑换，比如用 tokenA 兑换 tokenB，那 amountOut 就是指定想要换回的 tokenB 的数量，而需要支付的 tokenA 的数量则是越少越好。
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        // 用 amountOut 来计算得出需要多少 amountIn
        // 返回的 amounts 数组，第一个元素就是需要支付的 tokenA 数量
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    
    // 用指定的ETH换ERC20 token
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        // 支付的ETH是从msg.value中读取的
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        // 将ETH转成WETH之后再存到路由合约
        IWETH(WETH).deposit{value: amounts[0]}();
        // 将WETH转到第一个配对合约
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
    }
    
    // 用ERC20 token换一定数量的ETH
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        //路径中最后一个是WETH
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        // 将WETH转成ETH之后提取到路由合约
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        // 将ETH从路由合约转到to地址
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    
    // 用指定数量的ERC20 token换ETH
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    
    // 用ETH换取指定数量的ERC20 token，剩余的ETH会退给用户
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // 核心逻辑
    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {//遍历每个路径：如a->b-c->d，需要分别交换a->b，b->c,c->d
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            //根据两个token获取配对合约
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output));
            uint amountInput;//实际转入的ERC20 token
            uint amountOutput;//根据实际转入的数量计算得出转出的数量（换取的量）
            { // scope to avoid stack too deep errors
            (uint reserve0, uint reserve1,) = pair.getReserves();//得到配对合约的两个token的储备量
            (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            // 因为input代币转账时可能会有损耗，所以在pair合约里实际收到多少代币，只能通过查出pair合约当前的余额，再减去该代币已保存的储备量，这才能计算出实际值。
            amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
            // 根据给定的两个token的储备量和输入的token数量，计算得到输出的token数量，该计算会扣掉0.3%的手续费    
            amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
    
    // 用指定数量的ERC20 token兑换ERC20 token，支持转账时扣费
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        // 1.将amountIn转账到pair合约
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        // 2.读取出接收地址在兑换路径中最后一个代币的余额
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        // 3.调用内部函数实现路径中的每一步兑换
        _swapSupportingFeeOnTransferTokens(path, to);
        // 4.验证接收者最终兑换得到的资产数量不能小于指定的最小值
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
        // 因为此类代币转账时可能会有损耗，所以就无法使用恒定乘积公式计算出最终兑换的资产数量，因此用交易后的余额减去交易前的余额来计算得出实际值。
    }
    
    // 用指定数量的ETH换ERC20 token，支持转账时扣费
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        uint amountIn = msg.value;
        // 将ETH换成WETH并存入路由合约
        IWETH(WETH).deposit{value: amountIn}();
        // 从路由合约转WETH到配对合约
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn));
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    //支持收税的根据精确的token交换尽量多的ETH
    function swapExactTokensForETHSupportingFeeOnTransferTokens( 
        uint amountIn, //交易支付代币token的数量
        uint amountOutMin, //交易获得ETH的最少数量wei
        address[] calldata path, //交易路径
        address to, //交易获得ETH的地址
        uint deadline //截止日期
    )
        external
        virtual
        override
        ensure(deadline)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));//这里先把平台币给到router合约，然后再从路由合约转到真正的to地址
        // 查询路由地址的WETH余额
        uint amountOut = IERC20(WETH).balanceOf(address(this));
        // 确保WETH余额不小于最小转出金额
        require(amountOut >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        // 将路由WETH余额转成ETH并提取到路由合约
        IWETH(WETH).withdraw(amountOut);
        // 将路由合约的ETH转到to地址
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountOut)
    {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountIn)
    {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
