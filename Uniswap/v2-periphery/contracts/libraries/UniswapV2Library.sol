pragma solidity >=0.5.0;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';

import "./SafeMath.sol";

library UniswapV2Library {
    using SafeMath for uint;

    //对两个 token 进行排序
    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) { 
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    //计算两个token的pair合约地址
    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) { 
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',//十六进制字面量，以关键字hex打头，后面紧跟用单或双引号包裹的字符串。如hex"001122ff"。在内部会被表示为二进制流。
                factory,
                keccak256(abi.encodePacked(token0, token1)), //根据两个代币地址计算出一个盐值
                // 下面是硬编码，该值其实是 UniswapV2Pair 合约的 creationCode 的哈希值
                // init hash code计算方式：keccak256(abi.encodePacked(type(UniswapV2Pair).creationCode));
                // 这里前面已经加了 hex 关键字，所以单引号里的哈希值就不再需要 0x 开头
                hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
            ))));
    }

    //获取两个token在池子里的储备量
    // fetches and sorts the reserves for a pair
    function getReserves(address factory, address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IUniswapV2Pair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // 对价计算：根据给定的两个 token 的储备量和其中一个 token 数量，计算得到另一个 token 等值的数值
    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        require(amountA > 0, 'UniswapV2Library: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        // reverseA / reverseB = amountA / amountB ==> amountA * reverseB = amountB * reverseA，按A和B的比例计算
        amountB = amountA.mul(reserveB) / reserveA;
    }

    //根据给定的两个token的储备量和输入的token数量，计算得到输出的token数量，该计算会扣掉0.3%的手续费
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        /*
        根据AMM（自动做市商，做市商也就流动性提供者LP）的原理，恒定乘积做市商CPMM基于函数[x * y = k]，兑换前后k值不变。因此，在不考虑交易手续费的情况下，以下公式会成立：
        reserveIn * reserveOut = (reserveIn + amountIn) * (reserveOut - amountOut)
        将右边的表达式展开，并推导下，就变成了：
        reserveIn * reserveOut = reserveIn * reserveOut + amountIn * reserveOut - (reserveIn + amountIn) * amountOut
        ->
        amountIn * reserveOut = (reserveIn + amountIn) * amountOut
        ->
        amountOut = amountIn * reserveOut / (reserveIn + amountIn)
        实际上交易时，还需要扣除千分之三的手续费，所以实际上：
        amountIn = amountIn * 997 / 1000
        代入上面的公式，最终结果就变成了：
        amountOut = (amountIn * 997 / 1000) * reserveOut / (reserveIn + amountIn * 997 / 1000)
        ->
        amountOut = amountIn * 997 * reserveOut / (1000 * (reserveIn + amountIn * 997 / 1000))
        ->
        amountOut = amountIn * 997 * reserveOut / (reserveIn * 1000 + amountIn * 997)
        */
        // amountInWithFee = amountIn * 997
        uint amountInWithFee = amountIn.mul(997);
        // 分子numerator = amountIn * 997 * reserveOut
        uint numerator = amountInWithFee.mul(reserveOut);
        // 分母denominator = reserveIn * 1000 + amountIn * 997
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        // amountOut = amountIn * 997 * reserveOut / (reserveIn * 1000 + amountIn * 997)
        amountOut = numerator / denominator;
    }

    // 根据给定的两个token的储备量和输出的token数量，计算得到输入的token数量，该计算会扣减掉0.3%的手续费
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        /*
        根据AMM的原理，恒定乘积公式[x * y = k]，兑换前后k值不变。因此，在不考虑交易手续费的情况下，以下公式会成立：
        reserveIn * reserveOut = (reserveIn + amountIn) * (reserveOut - amountOut)
        将右边的表达式展开，并推导下，就变成了：
        reserveIn * reserveOut = reserveIn * reserveOut + amountIn * reserveOut - (reserveIn + amountIn) * amountOut
        ->
        amountIn * reserveOut = (reserveIn + amountIn) * amountOut
        ->
        amountIn = (reserveIn + amountIn) * amountOut / reserveOut
        实际上交易时，还需要扣除千分之三的手续费，所以实际上：
        amountIn = amountIn * 997 / 1000
        代入上面的公式，最终结果就变成了：
        amountIn * 997 / 1000 = (reserveIn +  amountIn * 997 / 1000) * amountOut / reserveOut
        ->
        amountIn * 997 = (reserveIn * 1000 + amountIn * 997) * amountOut / reserveOut
        ->
        amountIn * 997 = reserveIn * 1000 * amountOut / reserveOut + amountIn * 997 * amountOut / reserveOut
        amountIn * 997 * (1 - amountOut / reserveOut) = reserveIn * 1000 * amountOut / reserveOut
        amountIn * 997 * (reserveOut - amountOut) = reserveIn * 1000 * amountOut
        amountIn = reserveIn * 1000 * amountOut / (997 * (reserveOut - amountOut))
        */
        // numerator = reserveIn * amountOut * 1000
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        // denominator = (reserveOut - amountOut) * 997
        uint denominator = reserveOut.sub(amountOut).mul(997);
        // amountIn = (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1 , 加1用来round up
        amountIn = (numerator / denominator).add(1);//add(1) round up，强制x*y=k
    }

    // 根据兑换路径和输入数量，计算得到兑换路径中每个交易对的输出数量
    /*
    该函数会计算path中每一个中间资产和最终资产的数量，比如path为[A,B,C]，则会先将A兑换成B，再将B兑换成C。
    返回的是一个数组，第一个数组是A的数量，即amountIn，而第二个元素则是兑换到的代币B的数量，最后一个元素是最终要兑换得到的代币C的数量。
    每一次兑换其实都调用了getAmountOut函数，这也意味着每一次中间兑换都会扣减千分之三的交易手续费。
    那如果兑换两次，实际支付假设1000，那么最终兑换得到的价值只剩下：1000 * 0.997 * 0.997 = 994.009
    即实际支付的交易手续费将接近千分之六。兑换路径越长，实际扣减的交易手续费会更多，所以兑换路径一般不宜过长。
    */
    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(address factory, uint amountIn, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    // 根据兑换路径和输出数量，计算得到兑换路径中每个交易对的输入数量
    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(address factory, uint amountOut, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
